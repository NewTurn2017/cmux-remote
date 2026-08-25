import NIOCore
import NIOWebSocket

/// Adapts a weakly held NIO WebSocket handler context to the output pump's event-loop seam.
final class NIOWebSocketOutputChannel: WebSocketOutputChannel {
    private weak var context: ChannelHandlerContext?
    let eventLoop: any EventLoop

    init(context: ChannelHandlerContext) {
        self.context = context
        self.eventLoop = context.eventLoop
    }

    var isActive: Bool { context?.channel.isActive ?? false }
    var isWritable: Bool { context?.channel.isWritable ?? false }

    func writeText(_ text: String) -> EventLoopFuture<Void> {
        guard let context else {
            return eventLoop.makeFailedFuture(WebSocketOutputChannelError.closed)
        }
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(NIOAny(frame), promise: promise)
        return promise.futureResult
    }

    func close() {
        context?.close(promise: nil)
    }
}
