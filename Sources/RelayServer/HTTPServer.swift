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
    public let group: MultiThreadedEventLoopGroup
    public let routes: Routes
    public let auth: AuthService
    public let deviceStore: DeviceStore
    public let sessionManager: SessionManager
    public let cmux: CMUXFacade
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

        let bs = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { @Sendable ch, head in
                        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
                        guard path == "/v1/ws",
                              HTTPServer.deviceIdFromWSHeaders(head.headers, store: store) != nil
                        else {
                            return ch.eventLoop.makeSucceededFuture(nil)
                        }
                        // URLSessionWebSocketTask validates the negotiated
                        // `Sec-WebSocket-Protocol` against the *first*
                        // entry it offered (Apple's implementation is
                        // stricter than RFC 6455 here). Echo that exact
                        // first offered token so the iOS handshake closes
                        // cleanly instead of `NSURLErrorBadServerResponse`.
                        let offered = (head.headers.first(name: "Sec-WebSocket-Protocol") ?? "")
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        var responseHeaders = HTTPHeaders()
                        if let echoed = offered.first {
                            responseHeaders.add(name: "Sec-WebSocket-Protocol", value: echoed)
                        }
                        return ch.eventLoop.makeSucceededFuture(responseHeaders)
                    },
                    upgradePipelineHandler: { @Sendable ch, head in
                        let did = HTTPServer.deviceIdFromWSHeaders(head.headers, store: store) ?? ""
                        let handler = WebSocketHandler(deviceId: did,
                                                       deviceStore: store,
                                                       sessionManager: manager,
                                                       cmuxClient: cmux)
                        return ch.pipeline.addHandler(handler)
                    }
                )
                let httpHandler = HTTPHandler(routes: routes, deviceStore: store)
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

    // MARK: - Bearer extraction

    /// Resolve `Authorization: Bearer <token>` against the device store.
    /// Returns `nil` if the header is missing, malformed, or no device
    /// validates the token. `nil` is passed to `Routes.handle` so each
    /// endpoint can choose between rejecting (401) or proceeding
    /// anonymously (e.g. `/v1/health`, `/v1/devices/me/register`).
    static func deviceIdFromAuthHeader(_ headers: HTTPHeaders,
                                       store: DeviceStore) -> String?
    {
        guard let value = headers.first(name: "Authorization") else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let prefix = "Bearer "
        guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        let token = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        if token.isEmpty { return nil }
        for d in store.allDevices() where store.validate(deviceId: d.deviceId, token: token) {
            return d.deviceId
        }
        return nil
    }

    /// Resolve `Sec-WebSocket-Protocol: cmuxremote.v1, bearer.<token>` for
    /// WS upgrade requests. Same validation contract as
    /// `deviceIdFromAuthHeader` but pulls the token from the WS subprotocol
    /// list because browsers don't let JS set `Authorization` on WS opens.
    static func deviceIdFromWSHeaders(_ headers: HTTPHeaders,
                                      store: DeviceStore) -> String?
    {
        // Native iOS clients can ride the bearer on the standard
        // `Authorization: Bearer <token>` header — URLSessionWebSocketTask
        // strips custom values from `Sec-WebSocket-Protocol`. Browsers
        // that can't set Authorization continue to use the legacy
        // subprotocol form `bearer.<token>`.
        let candidates: [String] = {
            var tokens: [String] = []
            if let auth = headers.first(name: "Authorization"),
               auth.hasPrefix("Bearer ")
            {
                let trimmed = String(auth.dropFirst("Bearer ".count))
                    .trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { tokens.append(trimmed) }
            }
            if let proto = headers.first(name: "Sec-WebSocket-Protocol") {
                let parts = proto.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                for part in parts where part.hasPrefix("bearer.") {
                    let token = String(part.dropFirst("bearer.".count))
                    if !token.isEmpty { tokens.append(token) }
                }
            }
            return tokens
        }()
        for token in candidates {
            for d in store.allDevices() where store.validate(deviceId: d.deviceId, token: token) {
                return d.deviceId
            }
        }
        return nil
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
    private let deviceStore: DeviceStore
    private var pendingHead: HTTPRequestHead?
    private var bodyBuffer = ByteBuffer()
    private var deviceId: String?

    init(routes: Routes, deviceStore: DeviceStore) {
        self.routes = routes
        self.deviceStore = deviceStore
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            pendingHead = head
            bodyBuffer.clear()
            deviceId = HTTPServer.deviceIdFromAuthHeader(head.headers, store: deviceStore)

        case .body(var buf):
            bodyBuffer.writeBuffer(&buf)

        case .end:
            guard let head = pendingHead else { return }
            let body: Data? = bodyBuffer.readableBytes > 0
                ? bodyBuffer.getData(at: bodyBuffer.readerIndex,
                                     length: bodyBuffer.readableBytes)
                : nil
            let did = deviceId
            // `description` formats as `[IPv4]127.0.0.1/127.0.0.1:54321`
            // which doesn't survive `stripPort`. The whois layer wants the
            // bare IP — ipAddress gives just that.
            let remote = context.remoteAddress?.ipAddress ?? ""
            let routes = self.routes
            let loop = context.eventLoop
            Task { [weak self] in
                let resp = await routes.handle(method: head.method,
                                               path: head.uri,
                                               body: body,
                                               deviceId: did,
                                               remoteAddr: remote)
                loop.execute {
                    self?.respond(context: context, resp: resp)
                }
            }
            pendingHead = nil
            deviceId = nil
        }
    }

    private func respond(context: ChannelHandlerContext, resp: HTTPResponseLite) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(resp.body?.count ?? 0)")
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1,
                                    status: resp.status,
                                    headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if let body = resp.body, !body.isEmpty {
            var buf = context.channel.allocator.buffer(capacity: body.count)
            buf.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
