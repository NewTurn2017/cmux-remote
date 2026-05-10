import Testing
@testable import RelayCore
import SharedKit

@Suite("RowState")
struct RowStateTests {
    @Test func ingestProducesEmptyOpsOnFirstCall() {
        var state = RowState()
        let scr = Screen(rev: 1, rows: ["a","b"], cols: 1, cursor: .init(x: 0, y: 0))
        let ops = state.ingest(snapshot: scr)
        // First call should emit a full snapshot (clear + rows + cursor).
        #expect(ops.contains(.clear))
        #expect(ops.contains(.row(y: 0, text: "a")))
        #expect(ops.contains(.row(y: 1, text: "b")))
    }

    @Test func subsequentEqualSnapshotIsEmpty() {
        var state = RowState()
        let scr = Screen(rev: 1, rows: ["a"], cols: 1, cursor: .init(x: 0, y: 0))
        _ = state.ingest(snapshot: scr)
        let ops = state.ingest(snapshot: scr)
        #expect(ops.isEmpty)
    }

    @Test func onlyChangedRowsEmit() {
        var state = RowState()
        _ = state.ingest(snapshot: Screen(rev: 1, rows: ["a","b","c"], cols: 1,
                                          cursor: .init(x: 0, y: 0)))
        let ops = state.ingest(snapshot: Screen(rev: 2, rows: ["a","B","c"], cols: 1,
                                                cursor: .init(x: 0, y: 0)))
        #expect(ops == [.row(y: 1, text: "B")])
    }
}
