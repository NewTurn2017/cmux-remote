import CMUXClient
import Foundation
import SharedKit
import Testing
@_spi(RelayServer) @testable import RelayCore

@Suite("SessionStyledReconcileTests")
struct SessionStyledReconcileTests {
    @Test func initialSnapshotIsAFullFrame() async throws {
        let styledRow = "\u{1B}[38;2;234;234;234;48;2;40;50;40mstyled\u{1B}[0m"
        let reader = SessionStaticReader([
            Screen(
                rev: 99,
                rows: [styledRow],
                cols: 6,
                cursor: CursorPos(x: 5, y: 0),
                snapshotMetadata: Self.metadata(epoch: "epoch-a", revision: 1)
            ),
        ])
        let manager = SessionManager(reader: reader, defaultFps: 15, idleFps: 5)
        let frames = FrameInbox()
        let session = await manager.attach(deviceId: "device") { frames.append($0) }
        try await session.subscribe(workspaceId: "workspace", surfaceId: "surface", lines: 120)
        let hub = try #require(await manager.renderHub(surfaceId: "surface"))

        await hub.tick()

        guard case .screenFull(let full)? = frames.snapshot().first else {
            Issue.record("the first authoritative snapshot must be screen.full")
            await manager.detach(session: session)
            return
        }
        #expect(full.rows == [styledRow])
        #expect(full.cols == 6)
        #expect(full.rowsCount == 1)
        #expect(full.cursor == CursorPos(x: 5, y: 0))
        await manager.detach(session: session)
    }

    @Test func stableGeometryUsesDiffAfterInitialFull() async throws {
        let first = Screen(
            rev: 0,
            rows: ["first", "same"],
            cols: 8,
            cursor: CursorPos(x: 0, y: 0),
            snapshotMetadata: Self.metadata(epoch: "epoch-a", revision: 1)
        )
        let second = Screen(
            rev: 0,
            rows: ["second", "same"],
            cols: 8,
            cursor: CursorPos(x: 1, y: 0),
            snapshotMetadata: Self.metadata(epoch: "epoch-a", revision: 2)
        )
        let reader = SessionStaticReader([first, second])
        let manager = SessionManager(reader: reader, defaultFps: 15, idleFps: 5)
        let frames = FrameInbox()
        let session = await manager.attach(deviceId: "device") { frames.append($0) }
        try await session.subscribe(workspaceId: "workspace", surfaceId: "surface", lines: 120)
        let hub = try #require(await manager.renderHub(surfaceId: "surface"))

        await hub.tick()
        await hub.tick()

        let snapshot = frames.snapshot()
        #expect(snapshot.count == 2)
        guard snapshot.count == 2,
              case .screenFull = snapshot[0],
              case .screenDiff(let diff) = snapshot[1]
        else {
            Issue.record("expected initial full followed by one diff")
            await manager.detach(session: session)
            return
        }
        #expect(diff.ops == [
            .row(y: 0, text: "second"),
            .cursor(x: 1, y: 0),
        ])
        #expect(!diff.ops.contains(.clear))
        await manager.detach(session: session)
    }

    @Test func geometryAndEpochChangesUseFullFrames() async throws {
        let first = Screen(
            rev: 0,
            rows: ["one"],
            cols: 3,
            cursor: CursorPos(x: 0, y: 0),
            snapshotMetadata: Self.metadata(epoch: "epoch-a", revision: 1)
        )
        let resized = Screen(
            rev: 0,
            rows: ["one", "two"],
            cols: 4,
            cursor: CursorPos(x: 1, y: 1),
            snapshotMetadata: Self.metadata(epoch: "epoch-b", revision: 1, viewportRows: 2)
        )
        let reader = SessionStaticReader([first, resized])
        let manager = SessionManager(reader: reader, defaultFps: 15, idleFps: 5)
        let frames = FrameInbox()
        let session = await manager.attach(deviceId: "device") { frames.append($0) }
        try await session.subscribe(workspaceId: "workspace", surfaceId: "surface", lines: 120)
        let hub = try #require(await manager.renderHub(surfaceId: "surface"))

        await hub.tick()
        await hub.tick()

        let fulls = frames.snapshot().compactMap { frame -> ScreenFull? in
            guard case .screenFull(let full) = frame else { return nil }
            return full
        }
        #expect(fulls.count == 2)
        #expect(fulls.last?.cols == 4)
        #expect(fulls.last?.rowsCount == 2)
        #expect(fulls.last?.rows == ["one", "two"])
        await manager.detach(session: session)
    }

    @Test func twoSubscribersReceiveOneFullEachFromOneSharedRead() async throws {
        let reader = CountingSessionReader([
            Screen(rev: 0, rows: ["shared"], cols: 6, cursor: .hidden),
        ])
        let manager = SessionManager(reader: reader, defaultFps: 15, idleFps: 5)
        let firstFrames = FrameInbox()
        let secondFrames = FrameInbox()
        let first = await manager.attach(deviceId: "first") { firstFrames.append($0) }
        let second = await manager.attach(deviceId: "second") { secondFrames.append($0) }
        try await first.subscribe(workspaceId: "workspace", surfaceId: "surface", lines: 120)
        try await second.subscribe(workspaceId: "workspace", surfaceId: "surface", lines: 120)
        let hub = try #require(await manager.renderHub(surfaceId: "surface"))

        await hub.tick()

        #expect(await reader.readCount(surfaceId: "surface") == 1)
        #expect(firstFrames.snapshot().count == 1)
        #expect(secondFrames.snapshot().count == 1)
        guard case .screenFull = firstFrames.snapshot().first,
              case .screenFull = secondFrames.snapshot().first
        else {
            Issue.record("both subscribers must independently establish a full baseline")
            await manager.detach(session: first)
            await manager.detach(session: second)
            return
        }
        await manager.detach(session: first)
        await manager.detach(session: second)
    }

    @Test func lateSubscriberAndReconnectEachReceiveCurrentFull() async throws {
        let reader = CountingSessionReader([
            Screen(rev: 0, rows: ["current"], cols: 7, cursor: .hidden),
            Screen(rev: 0, rows: ["reconnected"], cols: 11, cursor: .hidden),
        ])
        let manager = SessionManager(reader: reader, defaultFps: 15, idleFps: 5)
        let firstFrames = FrameInbox()
        let first = await manager.attach(deviceId: "first") { firstFrames.append($0) }
        try await first.subscribe(workspaceId: "workspace", surfaceId: "surface", lines: 120)
        let firstHub = try #require(await manager.renderHub(surfaceId: "surface"))
        await firstHub.tick()

        let lateFrames = FrameInbox()
        let late = await manager.attach(deviceId: "late") { lateFrames.append($0) }
        try await late.subscribe(workspaceId: "workspace", surfaceId: "surface", lines: 120)
        #expect(await reader.readCount(surfaceId: "surface") == 1)
        guard case .screenFull(let lateFull)? = lateFrames.snapshot().first else {
            Issue.record("a late subscriber must receive the retained snapshot immediately")
            await manager.detach(session: first)
            await manager.detach(session: late)
            return
        }
        #expect(lateFull.rows == ["current"])

        await manager.detach(session: first)
        await manager.detach(session: late)

        let reconnectFrames = FrameInbox()
        let reconnect = await manager.attach(deviceId: "late") { reconnectFrames.append($0) }
        try await reconnect.subscribe(workspaceId: "workspace", surfaceId: "surface", lines: 120)
        let reconnectHub = try #require(await manager.renderHub(surfaceId: "surface"))
        await reconnectHub.tick()
        guard case .screenFull(let reconnectFull)? = reconnectFrames.snapshot().first else {
            Issue.record("a reconnected session must establish a new full baseline")
            await manager.detach(session: reconnect)
            return
        }
        #expect(reconnectFull.rows == ["reconnected"])
        #expect(await reader.readCount(surfaceId: "surface") == 2)
        await manager.detach(session: reconnect)
    }

    @Test func unchangedSnapshotAndStaleReplayDoNotRegressSessionRevision() async throws {
        let epoch = "00000000-0000-4000-8000-000000000001"
        let initial = Screen(
            rev: 0,
            rows: ["styled-2"],
            cols: 8,
            cursor: .hidden,
            snapshotMetadata: Self.metadata(epoch: epoch, revision: 2)
        )
        let stale = Screen(
            rev: 0,
            rows: ["stale-1"],
            cols: 7,
            cursor: .hidden,
            snapshotMetadata: Self.metadata(epoch: epoch, revision: 1)
        )
        let changed = Screen(
            rev: 0,
            rows: ["styled-3"],
            cols: 8,
            cursor: .hidden,
            snapshotMetadata: Self.metadata(epoch: epoch, revision: 3)
        )
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.renderOutcome(screen: initial, epoch: epoch, revision: 2)),
            .immediate(Self.renderOutcome(screen: initial, epoch: epoch, revision: 2)),
            .immediate(Self.renderOutcome(screen: stale, epoch: epoch, revision: 1)),
            .immediate(Self.renderOutcome(screen: changed, epoch: epoch, revision: 3)),
        ])
        let manager = SessionManager(
            terminalReader: source,
            defaultFps: 15,
            idleFps: 5,
            clockFactory: { ManualSurfaceRenderClock() }
        )
        let frames = FrameInbox()
        let session = await manager.attach(deviceId: "device") { frames.append($0) }
        try await session.subscribe(workspaceId: "workspace", surfaceId: "surface", lines: 120)
        let hub = try #require(await manager.renderHub(surfaceId: "surface"))

        for _ in 0..<4 {
            await hub.tick()
        }

        let output = frames.snapshot()
        #expect(output.count == 2)
        guard output.count == 2,
              case .screenFull(let full) = output[0],
              case .screenDiff(let diff) = output[1]
        else {
            Issue.record("duplicate and stale replay events must not produce output")
            await manager.detach(session: session)
            return
        }
        #expect(full.rev == 1)
        #expect(diff.rev == 2)
        #expect(await session.baselineRevision(surfaceId: "surface") == 2)
        await manager.detach(session: session)
    }

    @Test func themeChangeUsesFullWithoutResizeInDiff() async throws {
        let first = Screen(
            rev: 0,
            rows: ["\u{1B}[48;2;16;24;32mrow\u{1B}[0m"],
            cols: 3,
            cursor: .hidden,
            snapshotMetadata: Self.metadata(epoch: "epoch-a", revision: 1)
        )
        let themed = Screen(
            rev: 0,
            rows: ["\u{1B}[48;2;40;50;40mrow\u{1B}[0m"],
            cols: 3,
            cursor: .hidden,
            snapshotMetadata: ScreenSnapshotMetadata(
                renderEpoch: "epoch-a",
                renderRevision: 2,
                viewportRows: 1,
                terminalForeground: "#eaeaea",
                terminalBackground: "#283228",
                terminalThemeRevision: 2
            )
        )
        let reader = SessionStaticReader([first, themed])
        let manager = SessionManager(reader: reader, defaultFps: 15, idleFps: 5)
        let frames = FrameInbox()
        let session = await manager.attach(deviceId: "device") { frames.append($0) }
        try await session.subscribe(workspaceId: "workspace", surfaceId: "surface", lines: 120)
        let hub = try #require(await manager.renderHub(surfaceId: "surface"))

        await hub.tick()
        await hub.tick()

        let output = frames.snapshot()
        #expect(output.count == 2)
        #expect(output.allSatisfy { frame in
            if case .screenFull = frame { return true }
            return false
        })
        await manager.detach(session: session)
    }

    @Test func sessionCloseRetiresEveryStreamAndReconnectUsesFreshIdentity() async throws {
        let manager = SessionManager(
            reader: SessionStaticReader([]),
            defaultFps: 15,
            idleFps: 5
        )
        let events = AsyncStream<SessionOutboundEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        let probe = await BoundedAsyncStreamProbe.make(stream: events.stream)
        let session = await manager.attachForBoundedOutputEvents(
            deviceId: "device",
            sendOutputEvent: { events.continuation.yield($0) }
        )
        try await session.subscribe(workspaceId: "workspace", surfaceId: "first", lines: 120)
        try await session.subscribe(workspaceId: "workspace", surfaceId: "second", lines: 120)

        await manager.detach(session: session)

        let firstEvent = try await probe.next()
        let secondEvent = try await probe.next()
        let retired = [firstEvent, secondEvent].compactMap { event -> (String, UUID)? in
            guard case .retire(let surfaceId, let streamIdentity) = event else { return nil }
            return (surfaceId, streamIdentity)
        }
        #expect(Set(retired.map(\.0)) == ["first", "second"])
        #expect(Set(retired.map(\.1)).count == 2)
        #expect(await session.activeSurfaceCount == 0)
        #expect(await session.sendAuthoritativeFull(surfaceId: "first") == false)

        let reconnect = await manager.attachForBoundedOutputEvents(
            deviceId: "device",
            sendOutputEvent: { events.continuation.yield($0) }
        )
        try await reconnect.subscribe(
            workspaceId: "workspace",
            surfaceId: "first",
            lines: 120
        )
        await manager.detach(session: reconnect)
        guard case .retire(let surfaceId, let reconnectIdentity) = try await probe.next() else {
            Issue.record("reconnect close must retire its fresh stream")
            return
        }
        #expect(surfaceId == "first")
        #expect(!Set(retired.map(\.1)).contains(reconnectIdentity))
    }

    @Test func firstAndRepeatedRecoveryRequestsEachSendRetainedStyledFull() async throws {
        let styled = "\u{1B}[38;2;234;234;234;48;2;40;50;40mgreen\u{1B}[0m"
        let reader = CountingSessionReader([
            Screen(rev: 0, rows: [styled], cols: 5, cursor: CursorPos(x: 5, y: 0)),
        ])
        let manager = SessionManager(reader: reader, defaultFps: 15, idleFps: 5)
        let frames = FrameInbox()
        let session = await manager.attach(deviceId: "device") { frames.append($0) }
        try await session.subscribe(workspaceId: "workspace", surfaceId: "surface", lines: 120)
        let hub = try #require(await manager.renderHub(surfaceId: "surface"))
        await hub.tick()
        let readsBeforeRecovery = await reader.readCount(surfaceId: "surface")

        #expect(await session.sendAuthoritativeFull(surfaceId: "surface"))
        #expect(await session.sendAuthoritativeFull(surfaceId: "surface"))

        let fulls = frames.snapshot().compactMap { frame -> ScreenFull? in
            guard case .screenFull(let full) = frame else { return nil }
            return full
        }
        #expect(fulls.count == 3)
        #expect(fulls.allSatisfy { $0.rows == [styled] })
        #expect(fulls.allSatisfy { $0.rev == fulls[0].rev })
        #expect(await reader.readCount(surfaceId: "surface") == readsBeforeRecovery)
        await manager.detach(session: session)
    }

    @Test func checksumRecoveryUsesStyledHubSnapshotWithoutAnotherRead() async throws {
        let styled = "\u{1B}[38;2;234;234;234;48;2;40;50;40mgreen\u{1B}[0m"
        let reader = CountingSessionReader([
            Screen(rev: 0, rows: [styled], cols: 5, cursor: CursorPos(x: 5, y: 0)),
        ])
        let clock = ManualSurfaceRenderClock()
        let manager = SessionManager(
            terminalReader: LegacyTerminalSourceReader(reader: reader),
            defaultFps: 15,
            idleFps: 5,
            clockFactory: { clock }
        )
        let frames = FrameInbox()
        let session = await manager.attach(deviceId: "device") { frames.append($0) }
        try await session.subscribe(workspaceId: "workspace", surfaceId: "surface", lines: 120)
        let hub = try #require(await manager.renderHub(surfaceId: "surface"))

        await hub.tick()
        await clock.advanceTimeOnly(by: 6)
        await hub.tick()
        let readsBeforeRecovery = await reader.readCount(surfaceId: "surface")
        #expect(await session.sendAuthoritativeFull(surfaceId: "surface"))

        let output = frames.snapshot()
        #expect(output.count == 3)
        guard output.count == 3,
              case .screenFull(let initial) = output[0],
              case .screenChecksum = output[1],
              case .screenFull(let recovered) = output[2]
        else {
            Issue.record("checksum recovery must emit full from the retained hub snapshot")
            await manager.detach(session: session)
            return
        }
        #expect(initial.rows == [styled])
        #expect(recovered.rows == [styled])
        #expect(recovered.rev == initial.rev)
        #expect(await reader.readCount(surfaceId: "surface") == readsBeforeRecovery)
        await manager.detach(session: session)
    }

    private static func renderOutcome(
        screen: Screen,
        epoch: String,
        revision: UInt64
    ) -> CMUXTerminalReadOutcome {
        .updated(CMUXTerminalReadUpdate(
            screen: screen,
            sourceMode: .renderGrid,
            replayIdentity: CMUXTerminalReplayIdentity(epoch: epoch, revision: revision)
        ))
    }

    private static func metadata(
        epoch: String,
        revision: UInt64,
        viewportRows: Int = 1
    ) -> ScreenSnapshotMetadata {
        ScreenSnapshotMetadata(
            renderEpoch: epoch,
            renderRevision: revision,
            viewportRows: viewportRows,
            terminalForeground: "#eaeaea",
            terminalBackground: "#101820",
            terminalThemeRevision: 1
        )
    }
}
