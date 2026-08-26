import NIOCore
import NIOEmbedded
import NIOWebSocket
import Testing
@testable import RelayCore
@testable import RelayServer

@Suite("WebSocketHandlerLifecycleTests", .serialized)
struct WebSocketHandlerLifecycleTests {
    @Test func inactiveAndRemovedPipelineReleaseHandlerContextAndPumpCycle() throws {
        let store = try DeviceStore.empty()
        let manager = SessionManager(
            reader: FixtureSurfaceReader(),
            defaultFps: 15,
            idleFps: 5
        )
        weak var releasedHandler: WebSocketHandler?
        do {
            let handler = WebSocketHandler(
                deviceId: "device",
                deviceStore: store,
                sessionManager: manager,
                cmuxClient: SurfaceRenderHubNoOpFacade()
            )
            releasedHandler = handler
            let channel = EmbeddedChannel(handler: handler)
            try channel.close().wait()
            _ = try channel.finish(acceptAlreadyClosed: true)
        }

        #expect(releasedHandler == nil)
    }

    @Test func disconnectCancelsActiveRPCAndSuppressesQueuedRPC() async throws {
        let store = try DeviceStore.empty()
        let manager = SessionManager(
            reader: FixtureSurfaceReader(),
            defaultFps: 15,
            idleFps: 5
        )
        let facade = SuspendingInboundCMUXFacade()
        let cancellationProbe = await RelayServerBoundedStreamProbe.make(
            stream: facade.cancellations()
        )
        let handler = WebSocketHandler(
            deviceId: "device",
            deviceStore: store,
            sessionManager: manager,
            cmuxClient: facade,
            maximumOutstandingInboundActions: 3
        )
        let channel = await NIOAsyncTestingChannel(handler: handler)
        try await channel.connect(
            to: SocketAddress(unixDomainSocketPath: "/fake")
        ).get()

        try await channel.writeInbound(frame(
            #"{"deviceId":"device","appVersion":"1","protocolVersion":1}"#,
            allocator: channel.allocator
        ))
        try await channel.writeInbound(frame(
            #"{"id":"1","method":"slow.1","params":{}}"#,
            allocator: channel.allocator
        ))
        let startedProbe = await RelayServerBoundedStreamProbe.make(
            stream: facade.startedMethods()
        )
        #expect(try await startedProbe.next() == "slow.1")
        try await channel.writeInbound(frame(
            #"{"id":"2","method":"slow.2","params":{}}"#,
            allocator: channel.allocator
        ))

        _ = try await channel.finish()
        _ = try await cancellationProbe.next()
        #expect(await facade.startedSnapshot() == ["slow.1"])
        facade.release()
    }

    private func frame(
        _ text: String,
        allocator: ByteBufferAllocator
    ) -> WebSocketFrame {
        var buffer = allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        return WebSocketFrame(fin: true, opcode: .text, data: buffer)
    }
}
