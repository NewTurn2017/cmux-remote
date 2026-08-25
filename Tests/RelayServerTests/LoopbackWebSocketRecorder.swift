import Foundation
import NIOCore

/// Parses the HTTP upgrade and unmasked server WebSocket text frames on one client loop.
///
/// `@unchecked Sendable` is sound because NIO invokes all mutable parser state on one event loop.
final class LoopbackWebSocketRecorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let upgradeFuture: EventLoopFuture<Void>

    private let upgradePromise: EventLoopPromise<Void>
    private var bytes: [UInt8] = []
    private var upgraded = false
    private var messages: [String] = []
    private var messageWaiters: [EventLoopPromise<String>] = []

    init(eventLoop: any EventLoop) {
        let promise = eventLoop.makePromise(of: Void.self)
        upgradePromise = promise
        upgradeFuture = promise.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let incoming = buffer.readBytes(length: buffer.readableBytes) {
            bytes.append(contentsOf: incoming)
        }
        do {
            try parseAvailableBytes()
        } catch {
            fail(error)
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(LoopbackWebSocketError.closed)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    func nextText(on eventLoop: any EventLoop) -> EventLoopFuture<String> {
        precondition(eventLoop.inEventLoop)
        if !messages.isEmpty {
            return eventLoop.makeSucceededFuture(messages.removeFirst())
        }
        let promise = eventLoop.makePromise(of: String.self)
        messageWaiters.append(promise)
        return promise.futureResult
    }

    private func parseAvailableBytes() throws {
        if !upgraded {
            guard let headerEnd = headerTerminatorIndex() else { return }
            let headerBytes = Array(bytes[..<headerEnd])
            bytes.removeFirst(headerEnd + 4)
            let header = String(decoding: headerBytes, as: UTF8.self)
            guard header.contains(" 101 ") else {
                throw LoopbackWebSocketError.invalidUpgrade
            }
            upgraded = true
            upgradePromise.succeed(())
        }

        while let message = try parseFrame() {
            if let waiter = messageWaiters.first {
                messageWaiters.removeFirst()
                waiter.succeed(message)
            } else {
                messages.append(message)
            }
        }
    }

    private func parseFrame() throws -> String? {
        guard bytes.count >= 2 else { return nil }
        let first = bytes[0]
        let second = bytes[1]
        let opcode = first & 0x0F
        let masked = second & 0x80 != 0
        guard !masked else { throw LoopbackWebSocketError.invalidFrame }

        var headerLength = 2
        let shortLength = Int(second & 0x7F)
        let payloadLength: Int
        switch shortLength {
        case 0...125:
            payloadLength = shortLength
        case 126:
            guard bytes.count >= 4 else { return nil }
            payloadLength = Int(bytes[2]) << 8 | Int(bytes[3])
            headerLength = 4
        case 127:
            guard bytes.count >= 10 else { return nil }
            var length: UInt64 = 0
            for byte in bytes[2..<10] {
                length = length << 8 | UInt64(byte)
            }
            guard length <= UInt64(Int.max) else {
                throw LoopbackWebSocketError.invalidFrame
            }
            payloadLength = Int(length)
            headerLength = 10
        default:
            throw LoopbackWebSocketError.invalidFrame
        }

        guard bytes.count >= headerLength + payloadLength else { return nil }
        let payload = Array(bytes[headerLength..<(headerLength + payloadLength)])
        bytes.removeFirst(headerLength + payloadLength)
        if opcode == 0x8 {
            throw LoopbackWebSocketError.closed
        }
        guard opcode == 0x1 else { return try parseFrame() }
        guard let text = String(bytes: payload, encoding: .utf8) else {
            throw LoopbackWebSocketError.invalidFrame
        }
        return text
    }

    private func headerTerminatorIndex() -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) where bytes[index...index + 3] == [13, 10, 13, 10] {
            return index
        }
        return nil
    }

    private func fail(_ error: any Error) {
        if !upgraded {
            upgradePromise.fail(error)
            upgraded = true
        }
        let waiters = messageWaiters
        messageWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.fail(error)
        }
    }
}
