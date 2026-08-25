import Foundation
import NIOCore
import NIOPosix

/// Drives masked WebSocket text frames over a real loopback TCP channel.
///
/// `@unchecked Sendable` is sound because NIO owns channel mutation on its event loop and
/// the recorder is only invoked through that same loop.
final class LoopbackWebSocketClient: @unchecked Sendable {
    let channel: any Channel
    private let recorder: LoopbackWebSocketRecorder

    private init(channel: any Channel, recorder: LoopbackWebSocketRecorder) {
        self.channel = channel
        self.recorder = recorder
    }

    static func connect(
        group: MultiThreadedEventLoopGroup,
        host: String,
        port: Int,
        token: String
    ) async throws -> LoopbackWebSocketClient {
        let eventLoop = group.next()
        let recorder = LoopbackWebSocketRecorder(eventLoop: eventLoop)
        let channel = try await ClientBootstrap(group: eventLoop)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(2))
            .channelInitializer { channel in
                channel.pipeline.addHandler(recorder)
            }
            .connect(host: host, port: port)
            .get()
        let client = LoopbackWebSocketClient(channel: channel, recorder: recorder)

        let request = """
        GET /v1/ws HTTP/1.1\r
        Host: \(host):\(port)\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        Sec-WebSocket-Version: 13\r
        Sec-WebSocket-Protocol: cmuxremote.v1, bearer.\(token)\r
        \r
        """ + "\n"
        var buffer = channel.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        try await channel.writeAndFlush(buffer).get()
        _ = try await client.awaitBounded(recorder.upgradeFuture)
        return client
    }

    func prepareNextText() -> EventLoopFuture<String> {
        channel.eventLoop.flatSubmit {
            self.recorder.nextText(on: self.channel.eventLoop)
        }
    }

    func awaitText(_ future: EventLoopFuture<String>) async throws -> String {
        try await awaitBounded(future)
    }

    func sendText(_ text: String) async throws {
        let payload = Array(text.utf8)
        let mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        var encoded: [UInt8] = [0x81]
        switch payload.count {
        case 0...125:
            encoded.append(0x80 | UInt8(payload.count))
        case 126...65_535:
            encoded.append(0x80 | 126)
            encoded.append(UInt8((payload.count >> 8) & 0xFF))
            encoded.append(UInt8(payload.count & 0xFF))
        default:
            encoded.append(0x80 | 127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                encoded.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }
        encoded.append(contentsOf: mask)
        encoded.append(contentsOf: payload.enumerated().map { index, byte in
            byte ^ mask[index % mask.count]
        })

        var buffer = channel.allocator.buffer(capacity: encoded.count)
        buffer.writeBytes(encoded)
        try await channel.writeAndFlush(buffer).get()
    }

    func sendTextAwaitingResponse(_ text: String) async throws -> String {
        let response = prepareNextText()
        try await sendText(text)
        return try await awaitText(response)
    }

    func close() async {
        try? await channel.close().get()
    }

    private func awaitBounded<Value: Sendable>(
        _ future: EventLoopFuture<Value>
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await future.get()
            }
            group.addTask { [channel] in
                // A fail-safe deadline bounds a broken loopback channel; it is not synchronization.
                try await ContinuousClock().sleep(for: .seconds(2))
                try? await channel.close().get()
                throw LoopbackWebSocketError.timeout
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw LoopbackWebSocketError.closed
            }
            return value
        }
    }
}
