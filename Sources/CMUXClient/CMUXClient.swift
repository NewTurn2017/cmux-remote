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
}

public actor CMUXClient {
    private let channel: Channel
    private let requestTimeout: TimeAmount
    private let logger = Logger(label: "CMUXClient")

    private var pending: [String: CheckedContinuation<RPCResponse, Error>] = [:]
    private var pushHandler: (@Sendable (PushFrame) -> Void)?

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
        let id = UUID().uuidString
        let req = RPCRequest(id: id, method: method, params: params)
        let body = try JSONEncoder().encode(req)
        var buf = channel.allocator.buffer(capacity: body.count)
        buf.writeBytes(body)

        // Write request (happens on event loop, stays synchronized)
        channel.write(buf, promise: nil)
        channel.flush()

        // Wait for response with timeout
        return try await withCheckedThrowingContinuation { cont in
            // Register continuation
            self.pending[id] = cont

            // Schedule timeout
            _ = self.channel.eventLoop.scheduleTask(in: self.requestTimeout) { [weak self] in
                guard let self = self else { return }
                Task { await self.doTimeoutContinuation(id: id) }
            }
        }
    }

    private func doTimeoutContinuation(id: String) {
        if let c = self.pending.removeValue(forKey: id) {
            c.resume(throwing: CMUXClientError.timeout)
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
}
