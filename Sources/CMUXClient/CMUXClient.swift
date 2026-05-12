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

    public init(channel: Channel, requestTimeout: TimeAmount = .seconds(5)) {
        self.channel = channel
        self.requestTimeout = requestTimeout
        Task { await self.installInboundHandler() }
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
    }

    fileprivate func deliver(line: ByteBuffer) {
        // Called from channel handler via Task { await ... }
        guard let str = line.getString(at: 0, length: line.readableBytes),
              let data = str.data(using: .utf8) else { return }

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
