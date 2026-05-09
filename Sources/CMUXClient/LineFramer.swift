import NIOCore

public final class LineFrameDecoder: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer

    private var buffer = ByteBuffer()

    public init() {}

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = self.unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        while let nl = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) {
            let lineLength = nl - buffer.readerIndex
            if let line = buffer.readSlice(length: lineLength) {
                _ = buffer.readInteger(as: UInt8.self) // discard \n
                context.fireChannelRead(self.wrapInboundOut(line))
            }
        }
        if buffer.readableBytes == 0 { buffer.clear() }
    }
}

public final class LineFrameEncoder: ChannelOutboundHandler {
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    public init() {}

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buf = self.unwrapOutboundIn(data)
        buf.writeInteger(UInt8(ascii: "\n"))
        context.write(self.wrapOutboundOut(buf), promise: promise)
    }
}
