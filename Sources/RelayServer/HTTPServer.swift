import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import RelayCore
import SharedKit
import Logging

/// HTTP/1.1 server with WebSocket upgrade. Plain HTTP — TLS is provided by
/// Tailscale's wire encryption. Spec section 6.1, plan task 11.
///
/// Wiring:
/// - HTTP requests pass through `HTTPHandler`, which extracts a bearer
///   token from `Authorization: Bearer <token>`, validates it against
///   `DeviceStore`, and hands `Routes.handle` either the resolved
///   `deviceId` or `nil`. Routes itself decides which paths require auth.
/// - WS upgrade requests for `/v1/ws` go through `NIOWebSocketServerUpgrader`
///   whose `shouldUpgrade` parses `Sec-WebSocket-Protocol` for
///   `bearer.<token>` and rejects the upgrade if no device validates the
///   token. The `upgradePipelineHandler` installs `WebSocketHandler` with
///   the resolved `deviceId` so the WS layer never sees an unauthenticated
///   peer.
public final class HTTPServer: @unchecked Sendable {
    /// iPhone image uploads are sent as one JSON-RPC WebSocket text message
    /// containing base64 data. SwiftNIO's default WebSocket decoder limit is
    /// only 16 KiB, which makes normal Photos uploads close the socket before
    /// `file.upload` reaches `WebSocketHandler`.
    public static let maxWebSocketFrameBytes = 24 * 1024 * 1024

    public let group: MultiThreadedEventLoopGroup
    public let routes: Routes
    public let auth: AuthService
    public let deviceStore: DeviceStore
    public let sessionManager: SessionManager
    public let cmux: CMUXFacade
    private let uploadService: ChunkedFileUploadService
    private let artifactService: TerminalArtifactService
    public let logger = Logger(label: "HTTPServer")

    public init(group: MultiThreadedEventLoopGroup,
                routes: Routes,
                auth: AuthService,
                deviceStore: DeviceStore,
                sessionManager: SessionManager,
                cmux: CMUXFacade)
    {
        self.group = group
        self.routes = routes
        self.auth = auth
        self.deviceStore = deviceStore
        self.sessionManager = sessionManager
        self.cmux = cmux
        self.uploadService = ChunkedFileUploadService()
        self.artifactService = TerminalArtifactService(dispatchNative: { method, params in
            do {
                return .success(try await cmux.dispatch(method: method, params: params))
            } catch let error as RPCError {
                return .failure(code: error.code)
            } catch {
                return .failure(code: "internal_error")
            }
        })
    }

    init(group: MultiThreadedEventLoopGroup,
         routes: Routes,
         auth: AuthService,
         deviceStore: DeviceStore,
         sessionManager: SessionManager,
         cmux: CMUXFacade,
         uploadService: ChunkedFileUploadService,
         artifactService: TerminalArtifactService)
    {
        self.group = group
        self.routes = routes
        self.auth = auth
        self.deviceStore = deviceStore
        self.sessionManager = sessionManager
        self.cmux = cmux
        self.uploadService = uploadService
        self.artifactService = artifactService
    }

    /// Bind the server and return the listening channel. The caller is
    /// responsible for awaiting `closeFuture` (or calling `close()` when
    /// shutting down). Split from `run` so tests can bind on port 0 and
    /// read the bound port from `localAddress`.
    public func bind(host: String, port: Int) async throws -> Channel {
        let routes = self.routes
        let store = self.deviceStore
        let manager = self.sessionManager
        let cmux = self.cmux
        let sourceAuthorizer = BearerSourceAuthorizer(
            deviceStore: store,
            peerResolver: routes.registrationPeerResolver
        )
        let uploadService = self.uploadService
        let artifactService = self.artifactService

        let bs = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: HTTPServer.maxWebSocketFrameBytes,
                    shouldUpgrade: { @Sendable channel, head in
                        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
                        guard path == "/v1/ws",
                              let remote = channel.remoteAddress?.ipAddress else {
                            return channel.eventLoop.makeSucceededFuture(nil)
                        }
                        return channel.eventLoop.makeFutureWithTask {
                            guard case .authorized = await sourceAuthorizer.authorize(
                                headers: head.headers,
                                remoteAddress: remote
                            ) else { return nil }
                            let offered = (head.headers.first(name: "Sec-WebSocket-Protocol") ?? "")
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            var responseHeaders = HTTPHeaders()
                            if let echoed = offered.first {
                                responseHeaders.add(
                                    name: "Sec-WebSocket-Protocol",
                                    value: echoed
                                )
                            }
                            return responseHeaders
                        }
                    },
                    upgradePipelineHandler: { @Sendable channel, head in
                        let remote = channel.remoteAddress?.ipAddress ?? ""
                        return channel.eventLoop.makeFutureWithTask {
                            guard case let .authorized(deviceID) = await sourceAuthorizer.authorize(
                                headers: head.headers,
                                remoteAddress: remote
                            ) else {
                                throw RelayError.unauthorized(remote)
                            }
                            return deviceID
                        }.flatMap { deviceID in
                            let handler = WebSocketHandler(
                                deviceId: deviceID,
                                deviceStore: store,
                                sessionManager: manager,
                                cmuxClient: cmux,
                                uploadService: uploadService,
                                artifactService: artifactService
                            )
                            return channel.pipeline.addHandler(handler)
                        }
                    }
                )
                let httpHandler = HTTPHandler(
                    routes: routes,
                    sourceAuthorizer: sourceAuthorizer
                )
                let upgradeConfig: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { _ in
                        _ = channel.pipeline.removeHandler(httpHandler)
                    }
                )
                return channel.pipeline
                    .configureHTTPServerPipeline(withServerUpgrade: upgradeConfig)
                    .flatMap { channel.pipeline.addHandler(httpHandler) }
            }
        return try await bs.bind(host: host, port: port).get()
    }

    /// Blocking entry point — bind, log the bound address, and await
    /// `closeFuture`. Used from `cmux-relay serve`.
    public func run(host: String, port: Int) async throws {
        let chan = try await bind(host: host, port: port)
        logger.info("listening on \(chan.localAddress?.description ?? "?")")
        try await chan.closeFuture.get()
    }

}

// MARK: - HTTP request handler

/// Drains one HTTP request, hands it to `Routes.handle`, writes the
/// response, and closes the connection. Stateless across requests because
/// we always set `Connection: close` — keep-alive is intentionally
/// disabled for v1.0 to keep the request lifecycle obvious and avoid
/// pipelining edge cases that would interact badly with the WS upgrade
/// pipeline.
///
/// `@unchecked Sendable`: mutable per-request state (`pendingHead`,
/// `bodyBuffer`, `deviceId`) is only touched on the channel's event loop,
/// the same discipline `WebSocketHandler` follows.
private final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let routes: Routes
    private let sourceAuthorizer: BearerSourceAuthorizer
    private var pendingHead: HTTPRequestHead?
    private var bodyBuffer = ByteBuffer()

    init(routes: Routes, sourceAuthorizer: BearerSourceAuthorizer) {
        self.routes = routes
        self.sourceAuthorizer = sourceAuthorizer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            pendingHead = head
            bodyBuffer.clear()

        case .body(var buf):
            bodyBuffer.writeBuffer(&buf)

        case .end:
            guard let head = pendingHead else { return }
            let body: Data? = bodyBuffer.readableBytes > 0
                ? bodyBuffer.getData(at: bodyBuffer.readerIndex,
                                     length: bodyBuffer.readableBytes)
                : nil
            let remote = context.remoteAddress?.ipAddress ?? ""
            let routes = self.routes
            let sourceAuthorizer = self.sourceAuthorizer
            let responder = HTTPChannelResponder(context: context)
            Task {
                let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
                let deviceID: String?
                let authorizationUnavailable: Bool
                if path == "/v1/health" || path == "/v1/devices/me/register" {
                    deviceID = nil
                    authorizationUnavailable = false
                } else {
                    switch await sourceAuthorizer.authorize(
                        headers: head.headers,
                        remoteAddress: remote
                    ) {
                    case .authorized(let authorizedDeviceID):
                        deviceID = authorizedDeviceID
                        authorizationUnavailable = false
                    case .rejected:
                        deviceID = nil
                        authorizationUnavailable = false
                    case .identityUnavailable:
                        deviceID = nil
                        authorizationUnavailable = true
                    }
                }
                let response: HTTPResponseLite
                if authorizationUnavailable {
                    response = Routes.identityUnavailableResponse()
                } else {
                    response = await routes.handle(
                        method: head.method,
                        path: head.uri,
                        body: body,
                        deviceId: deviceID,
                        remoteAddr: remote
                    )
                }
                responder.send(response)
            }
            pendingHead = nil
        }
    }
}
