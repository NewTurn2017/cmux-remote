import Testing
@testable import CmuxRemote

@Suite("TerminalSelectionReducerTests")
struct TerminalSelectionReducerTests {
    @Test func recognizedPressMoveReverseAndEndAreDeterministic() throws {
        let epoch = try #require(TerminalGridEpoch(rawValue: 2))
        let snapshot = snapshot(["ABCD"])
        var reducer = TerminalSelectionReducer(epoch: epoch, revision: 10)

        #expect(reducer.reduce(.recognizedPress(
            snapshot: snapshot,
            at: position(0, 2),
            epoch: epoch
        )) == nil)
        #expect(reducer.phase == .selecting)
        #expect(reducer.selection?.text == "C")

        reducer.reduce(.move(to: position(0, 3), epoch: epoch))
        #expect(reducer.selection?.text == "CD")

        reducer.reduce(.reverse(to: position(0, 0), epoch: epoch))
        #expect(reducer.selection?.anchor == position(0, 2))
        #expect(reducer.selection?.focus == position(0, 0))
        #expect(reducer.selection?.text == "ABC")

        reducer.reduce(.end(epoch: epoch))
        #expect(reducer.phase == .selected)
        #expect(reducer.selection?.text == "ABC")
    }

    @Test func selectedStartBoundaryExpandsAndContracts() throws {
        let epoch = try #require(TerminalGridEpoch(rawValue: 2))
        let selectionSnapshot = snapshot(["ABCDE"])
        var reducer = TerminalSelectionReducer(epoch: epoch)
        reducer.reduce(.recognizedPress(snapshot: selectionSnapshot, at: position(0, 2), epoch: epoch))
        reducer.reduce(.move(to: position(0, 4), epoch: epoch))
        reducer.reduce(.end(epoch: epoch))

        #expect(reducer.reduce(.adjustBoundary(.start, to: position(0, 1), epoch: epoch)) == .boundaryAdjusted(.start))
        #expect(reducer.selection?.range.start == position(0, 1))
        #expect(reducer.selection?.range.end == position(0, 4))
        #expect(reducer.selection?.text == "BCDE")

        #expect(reducer.reduce(.adjustBoundary(.start, to: position(0, 3), epoch: epoch)) == .boundaryAdjusted(.start))
        #expect(reducer.selection?.range.start == position(0, 3))
        #expect(reducer.selection?.range.end == position(0, 4))
        #expect(reducer.selection?.text == "DE")
    }

    @Test func selectedEndBoundaryExpandsAndContracts() throws {
        let epoch = try #require(TerminalGridEpoch(rawValue: 2))
        let selectionSnapshot = snapshot(["ABCDE"])
        var reducer = TerminalSelectionReducer(epoch: epoch)
        reducer.reduce(.recognizedPress(snapshot: selectionSnapshot, at: position(0, 1), epoch: epoch))
        reducer.reduce(.move(to: position(0, 3), epoch: epoch))
        reducer.reduce(.end(epoch: epoch))

        #expect(reducer.reduce(.adjustBoundary(.end, to: position(0, 4), epoch: epoch)) == .boundaryAdjusted(.end))
        #expect(reducer.selection?.range.start == position(0, 1))
        #expect(reducer.selection?.range.end == position(0, 4))
        #expect(reducer.selection?.text == "BCDE")

        #expect(reducer.reduce(.adjustBoundary(.end, to: position(0, 2), epoch: epoch)) == .boundaryAdjusted(.end))
        #expect(reducer.selection?.range.start == position(0, 1))
        #expect(reducer.selection?.range.end == position(0, 2))
        #expect(reducer.selection?.text == "BC")
    }

    @Test func crossingSwapsTheActiveBoundaryAndContinuesWithoutJumping() throws {
        let selectionSnapshot = snapshot(["ABCDEF"])
        let initial = try #require(TerminalSelection(
            snapshot: selectionSnapshot,
            anchor: position(0, 1),
            focus: position(0, 3)
        ))

        let crossed = try #require(initial.adjusting(.start, to: position(0, 4)))
        #expect(crossed.activeBoundary == .end)
        #expect(crossed.selection.range.start == position(0, 3))
        #expect(crossed.selection.range.end == position(0, 4))
        #expect(crossed.selection.text == "DE")

        let continued = try #require(crossed.selection.adjusting(
            crossed.activeBoundary,
            to: position(0, 5)
        ))
        #expect(continued.activeBoundary == .end)
        #expect(continued.selection.range.start == position(0, 3))
        #expect(continued.selection.range.end == position(0, 5))
        #expect(continued.selection.text == "DEF")
    }

    @Test func staleBoundaryAdjustmentIsIgnored() throws {
        let current = try #require(TerminalGridEpoch(rawValue: 3))
        let stale = try #require(TerminalGridEpoch(rawValue: 2))
        var reducer = TerminalSelectionReducer(epoch: current)
        reducer.reduce(.recognizedPress(snapshot: snapshot(["ABCD"]), at: position(0, 1), epoch: current))
        reducer.reduce(.move(to: position(0, 2), epoch: current))
        reducer.reduce(.end(epoch: current))
        let before = reducer.selection

        #expect(reducer.reduce(.adjustBoundary(.end, to: position(0, 3), epoch: stale)) == nil)
        #expect(reducer.selection == before)
        #expect(reducer.phase == .selected)
    }

    @Test func boundaryAdjustmentPreservesTheImmutableSnapshotText() throws {
        let epoch = try #require(TerminalGridEpoch(rawValue: 1))
        var grid = CellGrid(cols: 8, rows: 1)
        grid.replaceRow(0, raw: "ABCDE")
        let immutable = TerminalSelectionSnapshot(renderRows: grid.renderRows)
        var reducer = TerminalSelectionReducer(epoch: epoch)
        reducer.reduce(.recognizedPress(snapshot: immutable, at: position(0, 1), epoch: epoch))
        reducer.reduce(.move(to: position(0, 2), epoch: epoch))
        reducer.reduce(.end(epoch: epoch))

        grid.replaceRow(0, raw: "changed")
        reducer.reduce(.ordinaryRevisionChanged(to: 1))
        reducer.reduce(.adjustBoundary(.end, to: position(0, 4), epoch: epoch))

        #expect(reducer.selection?.snapshot == immutable)
        #expect(reducer.selection?.text == "BCDE")
        #expect(grid.renderRows[0].plainText == "changed")
    }

    @Test func copyExposesPlainTextWithoutWritingClipboardAndClearsState() throws {
        let epoch = try #require(TerminalGridEpoch(rawValue: 0))
        var reducer = TerminalSelectionReducer(epoch: epoch)
        reducer.reduce(.recognizedPress(snapshot: snapshot(["A한B"]), at: position(0, 3), epoch: epoch))
        reducer.reduce(.reverse(to: position(0, 1), epoch: epoch))
        reducer.reduce(.end(epoch: epoch))

        let effect = reducer.reduce(.copy(epoch: epoch))

        #expect(effect == .copyText("한B"))
        #expect(reducer.selection == nil)
        #expect(reducer.phase == .idle)
    }

    @Test func cancelPinchAndRepeatedInterruptionsAlwaysClear() throws {
        let epoch = try #require(TerminalGridEpoch(rawValue: 4))
        let press = TerminalSelectionReducerEvent.recognizedPress(
            snapshot: snapshot(["ABC"]),
            at: position(0, 1),
            epoch: epoch
        )
        var reducer = TerminalSelectionReducer(epoch: epoch)

        reducer.reduce(press)
        reducer.reduce(.cancel)
        reducer.reduce(.cancel)
        #expect(reducer.selection == nil)
        #expect(reducer.phase == .idle)

        reducer.reduce(press)
        reducer.reduce(.pinch)
        reducer.reduce(.pinch)
        #expect(reducer.selection == nil)
        #expect(reducer.phase == .idle)

        reducer.reduce(press)
        #expect(reducer.selection?.text == "B")
    }

    @Test func ordinaryRevisionPreservesImmutableSnapshotAndSelection() throws {
        let epoch = try #require(TerminalGridEpoch(rawValue: 1))
        var grid = CellGrid(cols: 4, rows: 1)
        grid.replaceRow(0, raw: "A한B")
        let immutable = TerminalSelectionSnapshot(renderRows: grid.renderRows)
        var reducer = TerminalSelectionReducer(epoch: epoch, revision: 7)
        reducer.reduce(.recognizedPress(snapshot: immutable, at: position(0, 1), epoch: epoch))

        grid.replaceRow(0, raw: "changed")
        reducer.reduce(.ordinaryRevisionChanged(to: 8))
        reducer.reduce(.move(to: position(0, 3), epoch: epoch))

        #expect(reducer.revision == 8)
        #expect(reducer.phase == .selecting)
        #expect(reducer.selection?.snapshot == immutable)
        #expect(reducer.selection?.text == "한B")
        #expect(grid.renderRows[0].plainText == "changed")
    }

    @Test func epochChangeClearsButSameAndStaleEpochEventsDoNotCorruptState() throws {
        let epoch = try #require(TerminalGridEpoch(rawValue: 5))
        let stale = try #require(TerminalGridEpoch(rawValue: 4))
        let next = try #require(TerminalGridEpoch(rawValue: 6))
        var reducer = TerminalSelectionReducer(epoch: epoch, revision: 11)
        reducer.reduce(.recognizedPress(snapshot: snapshot(["AB"]), at: position(0, 0), epoch: epoch))

        reducer.reduce(.epochChanged(to: epoch, reason: .fullSnapshot))
        #expect(reducer.selection?.text == "A")
        reducer.reduce(.epochChanged(to: stale, reason: .clear))
        #expect(reducer.epoch == epoch)
        #expect(reducer.selection?.text == "A")

        reducer.reduce(.epochChanged(to: next, reason: .surfaceChanged))
        #expect(reducer.epoch == next)
        #expect(reducer.selection == nil)
        #expect(reducer.phase == .idle)
    }

    @Test(arguments: TerminalGridEpochChangeReason.allCases)
    func everyDefinedGridInvalidationBoundaryClearsSelection(
        reason: TerminalGridEpochChangeReason
    ) throws {
        let epoch = try #require(TerminalGridEpoch(rawValue: 0))
        let next = try #require(TerminalGridEpoch(rawValue: 1))
        var reducer = TerminalSelectionReducer(epoch: epoch)
        reducer.reduce(.recognizedPress(snapshot: snapshot(["A"]), at: position(0, 0), epoch: epoch))

        reducer.reduce(.epochChanged(to: next, reason: reason))

        #expect(reducer.epoch == next)
        #expect(reducer.selection == nil)
        #expect(reducer.phase == .idle)
    }

    @Test func staleGestureAndCopyEventsAreRejectedWithoutMutation() throws {
        let current = try #require(TerminalGridEpoch(rawValue: 3))
        let stale = try #require(TerminalGridEpoch(rawValue: 2))
        var reducer = TerminalSelectionReducer(epoch: current)

        reducer.reduce(.recognizedPress(snapshot: snapshot(["AB"]), at: position(0, 0), epoch: stale))
        #expect(reducer.selection == nil)

        reducer.reduce(.recognizedPress(snapshot: snapshot(["AB"]), at: position(0, 0), epoch: current))
        reducer.reduce(.move(to: position(0, 1), epoch: stale))
        reducer.reduce(.reverse(to: position(0, 1), epoch: stale))
        reducer.reduce(.end(epoch: stale))
        #expect(reducer.selection?.text == "A")
        #expect(reducer.phase == .selecting)
        #expect(reducer.reduce(.copy(epoch: stale)) == nil)
        #expect(reducer.selection?.text == "A")
    }

    @Test func malformedSnapshotPositionsRangesEpochsAndRevisionsRejectDeterministically() throws {
        #expect(TerminalGridEpoch(rawValue: -1) == nil)
        let epoch = try #require(TerminalGridEpoch(rawValue: 0))
        let malformed = TerminalSelectionSnapshot(rows: [
            TerminalSelectionRow(spans: [
                TerminalColumnSpan(columns: 1..<2, text: "B"),
                TerminalColumnSpan(columns: 0..<1, text: "A"),
            ]),
        ])
        var reducer = TerminalSelectionReducer(epoch: epoch, revision: 2)

        reducer.reduce(.recognizedPress(snapshot: malformed, at: position(0, 0), epoch: epoch))
        reducer.reduce(.recognizedPress(snapshot: snapshot(["A"]), at: position(0, -1), epoch: epoch))
        reducer.reduce(.ordinaryRevisionChanged(to: -1))
        reducer.reduce(.ordinaryRevisionChanged(to: 1))

        #expect(reducer.selection == nil)
        #expect(reducer.phase == .idle)
        #expect(reducer.revision == 2)
    }

    @Test func taskFiveDriverPrintsRequiredBoundaryObservables() throws {
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 12)
        let selectionSnapshot = snapshot(["A한B"])
        let epoch = try #require(TerminalGridEpoch(rawValue: 1))
        let next = try #require(TerminalGridEpoch(rawValue: 2))
        let x16 = try #require(geometry.strictPosition(at: .init(x: 16, y: 8), in: selectionSnapshot))
        let cjkFirst = try #require(geometry.strictPosition(at: .init(x: 24, y: 8), in: selectionSnapshot))
        let cjkSecond = try #require(geometry.strictPosition(at: .init(x: 32, y: 8), in: selectionSnapshot))
        var reducer = TerminalSelectionReducer(epoch: epoch, revision: 1)
        reducer.reduce(.recognizedPress(snapshot: selectionSnapshot, at: position(0, 3), epoch: epoch))
        reducer.reduce(.reverse(to: position(0, 1), epoch: epoch))
        reducer.reduce(.end(epoch: epoch))
        let reverseText = reducer.selection?.text
        reducer.reduce(.ordinaryRevisionChanged(to: 2))
        let revisionPreserved = reducer.selection?.text == reverseText
        reducer.reduce(.epochChanged(to: next, reason: .reset))

        print("TASK5_X16_COLUMN=\(x16.column)")
        print("TASK5_CJK_SAME_POSITION=\(cjkFirst == cjkSecond)")
        print("TASK5_REVERSE_TEXT=\(reverseText ?? "nil")")
        print("TASK5_REVISION_PRESERVES_STATE=\(revisionPreserved)")
        print("TASK5_EPOCH_CHANGE_CLEARS=\(reducer.selection == nil)")

        #expect(x16.column == 0)
        #expect(cjkFirst == cjkSecond)
        #expect(reverseText == "한B")
        #expect(revisionPreserved)
        #expect(reducer.selection == nil)
    }

    private func position(_ row: Int, _ column: Int) -> TerminalGridPosition {
        TerminalGridPosition(row: row, column: column)
    }

    private func snapshot(_ rawRows: [String]) -> TerminalSelectionSnapshot {
        var grid = CellGrid(cols: 80, rows: rawRows.count)
        for (index, row) in rawRows.enumerated() {
            grid.replaceRow(index, raw: row)
        }
        return TerminalSelectionSnapshot(renderRows: grid.renderRows)
    }
}
