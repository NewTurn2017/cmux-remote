import Foundation
import NIOCore
import NIOPosix
import SharedKit
@testable import RelayServer
@testable import RelayCore

/// Boots a real `HTTPServer` on a loopback ephemeral port with mock
/// dependencies, plus a tiny raw-TCP HTTP client so tests exercise the
/// full NIO HTTP/1.1 + WS upgrade pipeline end-to-end.
///
/// Mirrors `Tests/CMUXClientTests/MTELGCmuxFixture.swift` — same
/// "real loopback channels, no EmbeddedChannel" pattern so async work
/// inside the server (Routes actor, SessionManager, hello timer) drains
/// against the running event loop without manual ticking.
final class HTTPServerFixture: @unchecked Sendable {
    let group: MultiThreadedEventLoopGroup
    let host: String = "127.0.0.1"
    let port: Int

    let deviceStore: DeviceStore
    let auth: MockAuthService
    let reader: FixtureSurfaceReader
    let sessionManager: SessionManager
    let cmux: FixtureCMUXFacade
    let routes: Routes
    let server: HTTPServer
    let serverChannel: Channel

    private init(group: MultiThreadedEventLoopGroup,
                 port: Int,
                 deviceStore: DeviceStore,
                 auth: MockAuthService,
                 reader: FixtureSurfaceReader,
                 sessionManager: SessionManager,
                 cmux: FixtureCMUXFacade,
                 routes: Routes,
                 server: HTTPServer,
                 serverChannel: Channel)
    {
        self.group = group
        self.port = port
        self.deviceStore = deviceStore
        self.auth = auth
        self.reader = reader
        self.sessionManager = sessionManager
        self.cmux = cmux
        self.routes = routes
        self.server = server
        self.serverChannel = serverChannel
    }

    static func make(allowLogin: [String] = ["a@b"],
                     peers: [String: PeerIdentity] = [
                         "127.0.0.1": .init(loginName: "a@b",
                                            hostname: "iPhone",
                                            os: "ios",
                                            nodeKey: "nk-fixture")
                     ]) async throws -> HTTPServerFixture
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let store = try DeviceStore.empty()
        let auth = MockAuthService(peers: peers)
        let reader = FixtureSurfaceReader()
        let manager = SessionManager(reader: reader, defaultFps: 15, idleFps: 5)
        let cmux = FixtureCMUXFacade()
        var cfg = RelayConfig.testValue
        cfg.allowLogin = allowLogin
        let routes = Routes(deviceStore: store, config: cfg, auth: auth)
        let server = HTTPServer(group: group, routes: routes, auth: auth,
                                deviceStore: store, sessionManager: manager,
                                cmux: cmux)
        let chan = try await server.bind(host: "127.0.0.1", port: 0)
        guard let port = chan.localAddress?.port else {
            throw FixtureError.noPort
        }
        return .init(group: group, port: port,
                     deviceStore: store, auth: auth, reader: reader,
                     sessionManager: manager, cmux: cmux, routes: routes,
                     server: server, serverChannel: chan)
    }

    func shutdown() async {
        try? await serverChannel.close().get()
        try? await group.shutdownGracefully()
    }

    // MARK: - Raw TCP HTTP client

    struct RawHTTPResponse: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data

        var bodyString: String { String(data: body, encoding: .utf8) ?? "" }
    }

    /// Connect to the server, write `request` verbatim, read until the
    /// server completes the response, parse the status line + headers +
    /// body. Times out after 2s.
    ///
    /// Timeout is wired on the event loop (`scheduleTask` → `promise.fail`)
    /// rather than via a `Task.sleep` race because `EventLoopFuture.get()`
    /// is not cooperatively cancellable — a TaskGroup race that throws on
    /// the sleeper would block the group forever waiting for the future
    /// task to finish.
    func rawRequest(_ request: String) async throws -> RawHTTPResponse {
        let loop = group.next()
        let promise: EventLoopPromise<Data> = loop.makePromise(of: Data.self)
        let collector = ResponseCollector(promise: promise)

        let ch = try await ClientBootstrap(group: group)
            .channelInitializer { ch in
                ch.pipeline.addHandler(collector)
            }
            .connect(host: host, port: port)
            .get()

        var buf = ch.allocator.buffer(capacity: request.utf8.count)
        buf.writeString(request)
        try await ch.writeAndFlush(buf).get()

        let timeoutTask = loop.scheduleTask(in: .seconds(2)) {
            promise.fail(FixtureError.timeout)
        }
        do {
            let data = try await promise.futureResult.get()
            timeoutTask.cancel()
            try? await ch.close().get()
            return Self.parse(data)
        } catch {
            timeoutTask.cancel()
            try? await ch.close().get()
            throw error
        }
    }

    static func parse(_ data: Data) -> RawHTTPResponse {
        let sep = Data([0x0d, 0x0a, 0x0d, 0x0a])
        guard let range = data.range(of: sep) else {
            return .init(statusCode: 0, headers: [:], body: data)
        }
        let headStr = String(data: data.subdata(in: 0..<range.lowerBound),
                             encoding: .utf8) ?? ""
        let lines = headStr.components(separatedBy: "\r\n")
        let statusLine = lines.first ?? ""
        let parts = statusLine.split(separator: " ", maxSplits: 2,
                                     omittingEmptySubsequences: true)
        let code = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon])
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }
        let body = data.subdata(in: range.upperBound..<data.count)
        return .init(statusCode: code, headers: headers, body: body)
    }

    enum FixtureError: Error { case timeout, noPort }
}

private final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var buffer = Data()
    private let promise: EventLoopPromise<Data>
    private var fulfilled = false

    init(promise: EventLoopPromise<Data>) { self.promise = promise }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            buffer.append(contentsOf: bytes)
            tryComplete()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete()
    }

    private func tryComplete() {
        let sep = Data([0x0d, 0x0a, 0x0d, 0x0a])
        guard let range = buffer.range(of: sep) else { return }
        let headStr = String(data: buffer.subdata(in: 0..<range.lowerBound),
                             encoding: .utf8) ?? ""
        let lines = headStr.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return }
        let parts = statusLine.split(separator: " ", maxSplits: 2,
                                     omittingEmptySubsequences: true)
        let code = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        // No-body responses → complete as soon as head is in.
        if code == 101 || code == 204 || code == 304 {
            complete(); return
        }
        var cl: Int? = nil
        for line in lines.dropFirst() where !line.isEmpty {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let v = line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)
                cl = Int(v)
            }
        }
        let bodyLen = buffer.count - range.upperBound
        if let c = cl, bodyLen >= c {
            complete()
        } else if cl == nil {
            // No Content-Length and not an upgrade — wait for channel close.
        }
    }

    private func complete() {
        guard !fulfilled else { return }
        fulfilled = true
        promise.succeed(buffer)
    }
}

// MARK: - Test doubles

final class FixtureSurfaceReader: SurfaceReader, @unchecked Sendable {
    func read(workspaceId: String, surfaceId: String, lines: Int) async throws -> Screen {
        Screen(rev: 0, rows: [], cols: 0, cursor: .init(x: 0, y: 0))
    }
}

final class FixtureCMUXFacade: CMUXFacade, @unchecked Sendable {
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        .object([:])
    }
}
