import NIOEmbedded
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
}
