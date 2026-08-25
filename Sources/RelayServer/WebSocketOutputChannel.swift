import NIOCore

/// Event-loop-confined channel operations required by the WebSocket output pump.
protocol WebSocketOutputChannel: AnyObject {
    var eventLoop: any EventLoop { get }
    var isActive: Bool { get }
    var isWritable: Bool { get }

    func writeText(_ text: String) -> EventLoopFuture<Void>
    func close()
}
