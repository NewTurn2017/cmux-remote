import NIOCore
@_spi(RelayServer) import RelayCore

/// A detachable, event-loop-confined channel and bounded output-pump owner.
final class WSChannelContext: @unchecked Sendable {
    private let eventLoop: any EventLoop
    private var context: ChannelHandlerContext?
    private var outputPump: WebSocketOutputPump?

    init(
        _ context: ChannelHandlerContext,
        maximumQueuedOutputBytes: Int = WebSocketHandler.defaultMaximumQueuedOutputBytes
    ) {
        precondition(context.eventLoop.inEventLoop)
        self.eventLoop = context.eventLoop
        self.context = context
        self.outputPump = WebSocketOutputPump(
            channel: NIOWebSocketOutputChannel(context: context),
            maximumQueuedBytes: maximumQueuedOutputBytes
        )
    }

    func detach(closeChannel: Bool = false) {
        precondition(eventLoop.inEventLoop)
        if closeChannel {
            outputPump?.close()
        } else {
            outputPump?.channelClosed()
        }
        outputPump = nil
        context = nil
    }

    func writeText(
        _ text: String,
        if shouldWrite: @escaping @Sendable () -> Bool
    ) {
        execute { [weak self] _ in
            guard shouldWrite() else { return }
            self?.outputPump?.enqueueCritical(text)
        }
    }

    func writeOutputEvent(
        _ event: SessionOutboundEvent,
        if shouldWrite: @escaping @Sendable () -> Bool
    ) {
        execute { [weak self] _ in
            guard shouldWrite(), let pump = self?.outputPump else { return }
            switch event {
            case .frame(let output):
                pump.enqueue(output)
            case .retire(let surfaceId, let streamIdentity):
                pump.retire(surfaceId: surfaceId, streamIdentity: streamIdentity)
            }
        }
    }

    func close(if shouldClose: @escaping @Sendable () -> Bool) {
        execute { [weak self] _ in
            guard shouldClose() else { return }
            self?.outputPump?.close()
        }
    }

    func writabilityChanged() {
        precondition(eventLoop.inEventLoop)
        outputPump?.writabilityChanged()
    }

    func setAutoRead(
        _ enabled: Bool,
        onFailure: @escaping @Sendable (any Error) -> Void
    ) {
        execute { context in
            context.channel.setOption(ChannelOptions.autoRead, value: enabled).whenFailure {
                onFailure($0)
            }
        }
    }

    private func execute(
        _ operation: @escaping @Sendable (ChannelHandlerContext) -> Void
    ) {
        eventLoop.execute { [weak self] in
            guard let context = self?.context else { return }
            operation(context)
        }
    }
}
