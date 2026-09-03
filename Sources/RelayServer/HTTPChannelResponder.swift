import NIOCore
import NIOHTTP1

/// Event-loop-confined responder for one HTTP channel. The wrapper is
/// `@unchecked Sendable` because every access to the NIO context is scheduled
/// onto its own event loop before the context is dereferenced.
final class HTTPChannelResponder: @unchecked Sendable {
    private let eventLoop: any EventLoop
    private weak var context: ChannelHandlerContext?

    init(context: ChannelHandlerContext) {
        precondition(context.eventLoop.inEventLoop)
        eventLoop = context.eventLoop
        self.context = context
    }

    func send(_ response: HTTPResponseLite) {
        eventLoop.execute { [self] in
            guard let context else { return }
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "\(response.body?.count ?? 0)")
            headers.add(name: "Connection", value: "close")
            for (name, value) in response.headers {
                headers.replaceOrAdd(name: name, value: value)
            }
            let head = HTTPResponseHead(
                version: .http1_1,
                status: response.status,
                headers: headers
            )
            context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
            if let body = response.body, !body.isEmpty {
                var buffer = context.channel.allocator.buffer(capacity: body.count)
                buffer.writeBytes(body)
                context.write(
                    NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))),
                    promise: nil
                )
            }
            context.writeAndFlush(
                NIOAny(HTTPServerResponsePart.end(nil))
            ).whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }
}
