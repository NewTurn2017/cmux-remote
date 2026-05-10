import XCTest
import NIOCore
import NIOEmbedded
import SharedKit
@testable import RelayCore

final class DiffEngineBehaviorTests: XCTestCase {
    /// Static fake reader: returns a queued sequence of snapshots in order.
    private actor StaticReader: SurfaceReader {
        var snapshots: [Screen]
        init(_ snapshots: [Screen]) { self.snapshots = snapshots }
        func read(workspaceId: String, surfaceId: String, lines: Int) async throws -> Screen {
            if snapshots.isEmpty { return Screen(rev: 0, rows: [], cols: 0, cursor: .init(x: 0, y: 0)) }
            return snapshots.removeFirst()
        }
    }

    /// Sendable inbox for diffs the engine emits, so the test can assert from
    /// outside the actor without sharing mutable state across hops.
    private actor DiffInbox {
        var batches: [[DiffOp]] = []
        func push(_ ops: [DiffOp]) { batches.append(ops) }
        func snapshot() -> [[DiffOp]] { batches }
    }

    func testEmitsFullSnapshotThenDiffs() async throws {
        let reader = StaticReader([
            Screen(rev: 1, rows: ["a","b"], cols: 1, cursor: .init(x: 0, y: 0)),
            Screen(rev: 2, rows: ["a","B"], cols: 1, cursor: .init(x: 1, y: 1)),
        ])
        let inbox = DiffInbox()
        let engine = DiffEngine(reader: reader, fps: 100, idleFps: 10,
                                workspaceId: "w", surfaceId: "s", lines: 2,
                                clock: FakeClock())
        await engine.setOnDiff { _, ops in
            Task { await inbox.push(ops) }
        }
        try await engine.tick()
        try await engine.tick()
        // Drain any pending Task hops queued by setOnDiff fanout.
        try await Task.sleep(nanoseconds: 5_000_000)
        let emitted = await inbox.snapshot()
        XCTAssertEqual(emitted.count, 2)
        XCTAssertTrue(emitted[0].contains(.clear))
        XCTAssertEqual(emitted[1], [.row(y: 1, text: "B"), .cursor(x: 1, y: 1)])
    }

    func testIdleAdaptationAfterNoInput() async throws {
        let reader = StaticReader([
            Screen(rev: 1, rows: ["a"], cols: 1, cursor: .init(x: 0, y: 0)),
            Screen(rev: 2, rows: ["a"], cols: 1, cursor: .init(x: 0, y: 0)),
        ])
        let clock = FakeClock()
        let engine = DiffEngine(reader: reader, fps: 30, idleFps: 5,
                                workspaceId: "w", surfaceId: "s", lines: 1,
                                clock: clock)
        try await engine.tick()
        clock.advance(by: 2.0)              // > 1.5s of no input
        try await engine.tick()
        let fpsAfterIdle = await engine.currentFps
        XCTAssertEqual(fpsAfterIdle, 5)
        await engine.noteUserInput()
        let fpsAfterInput = await engine.currentFps
        XCTAssertEqual(fpsAfterInput, 30)
    }
}
