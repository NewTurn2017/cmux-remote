import Foundation
import NIOCore
import NIOFoundationCompat
import Logging
import SharedKit

public enum CMUXClientError: Error, Equatable {
    case timeout
    case rpc(RPCError)
    case decoding(String)
    case channelClosed
    case serverMessage(String)
}

public actor CMUXClient {
    private let channel: Channel
    private let requestTimeout: TimeAmount
    private let logger = Logger(label: "CMUXClient")

    private var pending: [String: CheckedContinuation<RPCResponse, Error>] = [:]
    private var pushHandler: (@Sendable (PushFrame) -> Void)?
    private var terminalError: CMUXClientError?
    private var bridgeReady = false
    private var bridgeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(channel: Channel, requestTimeout: TimeAmount = .seconds(5)) {
        self.channel = channel
        self.requestTimeout = requestTimeout
        Task { await self.installInboundHandler() }
    }

    /// Await this from the construction site before issuing any RPC. The
    /// `installInboundHandler` task scheduled in `init` is racy with the
    /// first `call(...)` — without this gate the very first response (and
    /// every subsequent one, since `events.stream` keeps the line open)
    /// would arrive at a pipeline that has no inbound bridge yet and get
    /// silently dropped, which surfaces as `CMUXClientError.timeout` after
    /// 5 s.
    public func awaitReady() async {
        if bridgeReady { return }
        await withCheckedContinuation { bridgeWaiters.append($0) }
    }

    public func onEventStream(_ handler: @escaping @Sendable (PushFrame) -> Void) {
        self.pushHandler = handler
    }

    @discardableResult
    public func call(method: String, params: JSONValue) async throws -> RPCResponse {
        if let terminalError {
            throw terminalError
        }
        guard channel.isActive else {
            throw CMUXClientError.channelClosed
        }

        let id = UUID().uuidString
        let req = RPCRequest(id: id, method: method, params: params)
        let body = try JSONEncoder().encode(req)
        var buf = channel.allocator.buffer(capacity: body.count)
        buf.writeBytes(body)

        // Wait for response with timeout
        return try await withCheckedThrowingContinuation { cont in
            // Register continuation
            self.pending[id] = cont

            // Write request after registration so a fast local response cannot
            // beat the pending table entry.
            self.channel.writeAndFlush(buf).whenFailure { error in
                Task { await self.failContinuation(id: id, error: .channelClosed) }
            }

            // Schedule timeout
            _ = self.channel.eventLoop.scheduleTask(in: self.requestTimeout) { [weak self] in
                guard let self = self else { return }
                Task { await self.doTimeoutContinuation(id: id) }
            }
        }
    }

    /// Fire-and-forget write: encodes a request and flushes it without
    /// registering a continuation or awaiting a response. Used for the
    /// `events.stream` subscribe — cmux 0.64.12 acks it with a `cmux-events`
    /// subscription envelope that carries no matching RPC `id`, so awaiting a
    /// response (via `call`) would always pay the full request timeout before
    /// the stream is considered "attached".
    public func send(method: String, params: JSONValue) throws {
        if let terminalError { throw terminalError }
        guard channel.isActive else { throw CMUXClientError.channelClosed }
        let id = UUID().uuidString
        let req = RPCRequest(id: id, method: method, params: params)
        let body = try JSONEncoder().encode(req)
        var buf = channel.allocator.buffer(capacity: body.count)
        buf.writeBytes(body)
        // Fire-and-forget, but don't drop a write failure. Unlike `call`, there
        // is no pending continuation to fail, so a silently-dropped subscribe
        // would leave the event-stream supervisor blocked in `awaitClosed()` on
        // a half-dead channel with no events ever arriving. Close the channel so
        // `closeFuture` fires and the supervisor re-attaches.
        self.channel.writeAndFlush(buf).whenFailure { [weak self] error in
            Task { await self?.handleSendFailure(error) }
        }
    }

    private func handleSendFailure(_ error: Error) {
        logger.warning("fire-and-forget send failed; closing channel to trigger re-attach: \(String(describing: error))")
        if terminalError == nil { terminalError = .channelClosed }
        channel.close(promise: nil)
    }

    public func authenticate(password: String) async throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let response = try await call(
            method: "auth.login",
            params: .object(["password": .string(trimmed)])
        )
        if let error = response.error {
            throw CMUXClientError.rpc(error)
        }
        guard response.isOk else {
            throw CMUXClientError.decoding("auth.login returned ok=false without an RPC error")
        }
    }

    private func doTimeoutContinuation(id: String) {
        if let c = self.pending.removeValue(forKey: id) {
            c.resume(throwing: CMUXClientError.timeout)
        }
    }

    private func failContinuation(id: String, error: CMUXClientError) {
        if error == .channelClosed, terminalError == nil {
            terminalError = error
        }
        if let c = self.pending.removeValue(forKey: id) {
            c.resume(throwing: error)
        }
    }

    private func failAllPending(_ error: CMUXClientError, terminal: Bool = false) {
        if terminal, terminalError == nil {
            terminalError = error
        }
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func installInboundHandler() async {
        let handler = ClientInboundBridge(client: self)
        try? await channel.pipeline.addHandler(handler).get()
        bridgeReady = true
        let waiters = bridgeWaiters
        bridgeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    fileprivate func deliver(line: ByteBuffer) {
        // Called from channel handler via Task { await ... }
        guard let str = line.getString(at: 0, length: line.readableBytes),
              let data = str.data(using: .utf8) else { return }

        // cmux 0.64.12 `cmux-events` protocol. These frames carry their own
        // `id` (a per-boot sequence) and a `protocol` tag, so the RPCResponse
        // path below would decode them, find no matching pending request, and
        // silently drop them. Detect by the protocol tag and route by shape:
        // frames with category+name are events; the subscription envelope and
        // heartbeats have neither and are ignored (the subscribe is
        // fire-and-forget, so there is no pending call to resolve).
        if let env = try? JSONDecoder().decode(CmuxEventsFrame.self, from: data),
           env.protocolTag == "cmux-events" {
            if let category = env.category, let name = env.name {
                let frame = EventFrame(category: EventCategory(rawValue: category) ?? .unknown,
                                       name: name,
                                       payload: env.payload ?? .null)
                pushHandler?(.event(frame))
            }
            return
        }

        // Try response first
        if let resp = try? JSONDecoder().decode(RPCResponse.self, from: data) {
            if let cont = self.pending.removeValue(forKey: resp.id) {
                cont.resume(returning: resp)
            }
            return
        }

        // Try push frame
        if let push = try? JSONDecoder().decode(PushFrame.self, from: data) {
            pushHandler?(push)
            return
        }

        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ERROR:") {
            failAllPending(.serverMessage(trimmed), terminal: true)
        }
    }

    fileprivate func didClose() {
        failAllPending(.channelClosed, terminal: true)
    }

    /// True only while the underlying channel is live and no terminal
    /// (channelClosed) error has been recorded. `CmuxConnection` uses this
    /// to decide whether a cached client can be reused or must be re-dialed.
    public func isUsable() -> Bool {
        channel.isActive && terminalError == nil
    }

    /// Suspends until the underlying channel closes. The event-stream
    /// supervisor awaits this to know when to re-attach.
    public func awaitClosed() async {
        _ = try? await channel.closeFuture.get()
    }
}

private final class ClientInboundBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private weak var client: CMUXClient?
    init(client: CMUXClient) { self.client = client }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = self.unwrapInboundIn(data)
        let captured = buf
        Task { await self.client?.deliver(line: captured) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        Task { await self.client?.didClose() }
        context.fireChannelInactive()
    }
}

/// Top-level decode of a cmux 0.64.12 `cmux-events` frame. All fields are
/// optional so a single decode covers both the subscription envelope (which
/// has neither `category` nor `name`) and event frames (which have both). The
/// `protocol` tag is the discriminator that separates these from RPC responses.
private struct CmuxEventsFrame: Decodable {
    let protocolTag: String?
    let category: String?
    let name: String?
    let payload: JSONValue?

    enum CodingKeys: String, CodingKey {
        case protocolTag = "protocol"
        case category, name, payload
    }
}
