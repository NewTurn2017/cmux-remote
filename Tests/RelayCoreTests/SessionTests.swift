import Testing
import SharedKit
@testable import RelayCore

@Suite("SessionTests")
struct SessionTests {
    @Test func subscribeAcquiresHubAndUnsubscribeReleasesIt() async throws {
        let reader = SessionStaticReader([
            Screen(rev: 1, rows: ["x"], cols: 1, cursor: .init(x: 0, y: 0)),
        ])
        let manager = SessionManager(reader: reader, defaultFps: 30, idleFps: 5)
        let session = await manager.attach(deviceId: "d1") { _ in }
        try await session.subscribe(workspaceId: "w", surfaceId: "s", lines: 1)
        #expect(await session.activeSurfaceCount == 1)

        await session.unsubscribe(surfaceId: "s")
        #expect(await session.activeSurfaceCount == 0)
        await manager.detach(session: session)
    }
}
