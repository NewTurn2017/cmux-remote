import Testing
import SharedKit
@testable import RelayCore

@Suite("DiffEngineBehaviorTests")
struct DiffEngineBehaviorTests {
    /// Static fake reader: returns a queued sequence of snapshots in order.
    private actor StaticReader: SurfaceReader {
        var snapshots: [Screen]

        init(_ snapshots: [Screen]) {
            self.snapshots = snapshots
        }

        func read(workspaceId: String, surfaceId: String, lines: Int) -> Screen {
            if snapshots.isEmpty {
                return Screen(rev: 0, rows: [], cols: 0, cursor: .init(x: 0, y: 0))
            }
            return snapshots.removeFirst()
        }
    }

    @Test func emitsFullSnapshotThenDiffs() async throws {
        let reader = StaticReader([
            Screen(rev: 1, rows: ["a", "b"], cols: 1, cursor: .init(x: 0, y: 0)),
            Screen(rev: 2, rows: ["a", "B"], cols: 1, cursor: .init(x: 1, y: 1)),
        ])
        let engine = DiffEngine(
            reader: reader,
            fps: 100,
            idleFps: 10,
            workspaceId: "w",
            surfaceId: "s",
            lines: 2,
            clock: FakeClock()
        )
        try await confirmation("two diff batches after subscription", expectedCount: 2) { emitted in
            await engine.setOnDiff { _, ops in
                if ops.contains(.clear) {
                    #expect(ops.contains(.row(y: 0, text: "a")))
                    #expect(ops.contains(.row(y: 1, text: "b")))
                } else {
                    #expect(ops == [.row(y: 1, text: "B"), .cursor(x: 1, y: 1)])
                }
                emitted()
            }
            print("diffConsumerSubscribed=true")

            try await engine.tick()
            try await engine.tick()
            print("diffTicksTriggeredAfterSubscription=true boundedConfirmation=true")
        }
    }

    @Test func idleAdaptationAfterNoInput() async throws {
        let reader = StaticReader([
            Screen(rev: 1, rows: ["a"], cols: 1, cursor: .init(x: 0, y: 0)),
            Screen(rev: 2, rows: ["a"], cols: 1, cursor: .init(x: 0, y: 0)),
        ])
        let clock = FakeClock()
        let engine = DiffEngine(
            reader: reader,
            fps: 30,
            idleFps: 5,
            workspaceId: "w",
            surfaceId: "s",
            lines: 1,
            clock: clock
        )

        try await engine.tick()
        clock.advance(by: 2.0)
        try await engine.tick()
        #expect(await engine.currentFps == 5)

        await engine.noteUserInput()
        #expect(await engine.currentFps == 30)
    }
}
