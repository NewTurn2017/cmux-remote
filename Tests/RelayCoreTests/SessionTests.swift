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

    @Test func closeDuringPendingSubscribeRetiresTheLateLease() async throws {
        let observer = SuspendingSurfaceRenderHubRegistryObserver(
            suspensionPoint: .registration
        )
        let events = await BoundedAsyncStreamProbe.make(stream: observer.events())
        let registry = SurfaceRenderHubRegistry(
            reader: LegacyTerminalSourceReader(reader: SessionStaticReader([])),
            configuration: SurfaceRenderHubConfiguration(activeFps: 30, idleFps: 5),
            clockFactory: { ManualSurfaceRenderClock() },
            observer: observer
        )
        let session = Session(
            deviceId: "pending-close",
            renderRegistry: registry,
            sendFrame: { _ in }
        )

        let subscribe = Task {
            try await session.subscribe(
                workspaceId: "workspace",
                surfaceId: "surface",
                lines: 1
            )
        }
        #expect(try await events.next() == .started("surface"))
        _ = try await events.next() // reserved
        _ = try await events.next() // registered, now suspended before returning the lease

        await session.close()
        await observer.resumeNext()
        try await subscribe.value

        #expect(await session.activeSurfaceCount == 0)
        #expect(await registry.activeHubCount == 0)
        #expect(await registry.cleanupTaskCount == 0)
    }

    @Test func testCloseThenLateSubscribeDoesNotRecreateSurface() async throws {
        let manager = SessionManager(
            reader: SessionStaticReader([]),
            defaultFps: 30,
            idleFps: 5
        )
        let session = await manager.attach(deviceId: "closed") { _ in }

        await session.close()
        try await session.subscribe(
            workspaceId: "workspace",
            surfaceId: "late",
            lines: 1
        )

        #expect(await session.activeSurfaceCount == 0)
        #expect(await manager.activeRenderHubCount == 0)
        await manager.detach(session: session)
    }
}
