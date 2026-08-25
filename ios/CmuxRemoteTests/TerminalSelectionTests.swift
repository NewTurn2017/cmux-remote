import Testing
@testable import CmuxRemote

@Suite("TerminalSelectionTests")
struct TerminalSelectionTests {
    @Test func mixedWidthRowCachesExactSelectableSpans() {
        let row = renderRow("A한B")

        #expect(row.selectionRow.spans.map(\.columns) == [0..<1, 1..<3, 3..<4])
        #expect(row.selectionRow.spans.map(\.text) == ["A", "한", "B"])
    }

    @Test(arguments: [1, 2])
    func touchingEitherWideGlyphColumnCopiesItOnce(column: Int) throws {
        let snapshot = snapshot(["A한B"])
        let selection = try #require(TerminalSelection(
            snapshot: snapshot,
            anchor: TerminalGridPosition(row: 0, column: column),
            focus: TerminalGridPosition(row: 0, column: column)
        ))

        #expect(selection.text == "한")
    }

    @Test func forwardAndReverseSelectionsProduceEqualTextWithoutChangingDirection() throws {
        let snapshot = snapshot(["A한B"])
        let start = TerminalGridPosition(row: 0, column: 0)
        let end = TerminalGridPosition(row: 0, column: 3)
        let forward = try #require(TerminalSelection(snapshot: snapshot, anchor: start, focus: end))
        let reverse = try #require(TerminalSelection(snapshot: snapshot, anchor: end, focus: start))

        #expect(forward.text == "A한B")
        #expect(reverse.text == forward.text)
        #expect(reverse.anchor == end)
        #expect(reverse.focus == start)
        #expect(reverse.range == TerminalTextRange(start: start, end: end))
    }

    @Test func updatingFocusReturnsANewSelectionAndKeepsAnchorFixed() throws {
        let snapshot = snapshot(["A한B"])
        let anchor = TerminalGridPosition(row: 0, column: 1)
        let initial = try #require(TerminalSelection(snapshot: snapshot, anchor: anchor, focus: anchor))
        let updated = try #require(initial.updatingFocus(to: TerminalGridPosition(row: 0, column: 3)))

        #expect(initial.focus == anchor)
        #expect(updated.anchor == anchor)
        #expect(updated.focus == TerminalGridPosition(row: 0, column: 3))
        #expect(updated.text == "한B")
    }

    @Test func combiningMarkAttachesToItsBaseGlyph() throws {
        let row = renderRow("e\u{301}x")
        #expect(row.selectionRow.spans.map(\.columns) == [0..<1, 1..<2])
        #expect(row.selectionRow.spans.map(\.text) == ["e\u{301}", "x"])

        let selection = try #require(TerminalSelection(
            snapshot: TerminalSelectionSnapshot(rows: [row.selectionRow]),
            anchor: TerminalGridPosition(row: 0, column: 0),
            focus: TerminalGridPosition(row: 0, column: 0)
        ))
        #expect(selection.text == "e\u{301}")
    }

    @Test func multipleCombiningMarksStayAttachedInSourceOrderAcrossStyleBoundaries() throws {
        let raw = "\u{1B}[31me\u{1B}[32m\u{301}\u{1B}[34m\u{327}\u{1B}[0mx"
        let row = renderRow(raw)

        #expect(row.selectionRow.spans.map(\.columns) == [0..<1, 1..<2])
        #expect(row.selectionRow.spans[0].text == "e\u{301}\u{327}")
        let selection = try #require(TerminalSelection(
            snapshot: TerminalSelectionSnapshot(rows: [row.selectionRow]),
            anchor: TerminalGridPosition(row: 0, column: 0),
            focus: TerminalGridPosition(row: 0, column: 0)
        ))
        #expect(selection.text == "e\u{301}\u{327}")
    }

    @Test func explicitSpacesAndTrailingSpacesAreNeverTrimmedOrPadded() throws {
        let selection = try #require(TerminalSelection(
            snapshot: snapshot(["A  "], cols: 80),
            anchor: TerminalGridPosition(row: 0, column: 0),
            focus: TerminalGridPosition(row: 0, column: 2)
        ))

        #expect(selection.text == "A  ")
    }

    @Test func multilineSelectionPreservesBlankRowsAndDeterministicLineFeeds() throws {
        let selection = try #require(TerminalSelection(
            snapshot: snapshot(["A  ", "", " B "]),
            anchor: TerminalGridPosition(row: 0, column: 0),
            focus: TerminalGridPosition(row: 2, column: 2)
        ))

        #expect(selection.text == "A  \n\n B ")
    }

    @Test func ANSIStyleBoundariesNeverEnterCopiedText() throws {
        let raw = "\u{1B}[31mA\u{1B}[0m\u{1B}[48;2;40;50;40m한\u{1B}[0m\u{1B}[4mB\u{1B}[0m"
        let selection = try #require(TerminalSelection(
            snapshot: snapshot([raw]),
            anchor: TerminalGridPosition(row: 0, column: 0),
            focus: TerminalGridPosition(row: 0, column: 3)
        ))

        #expect(selection.text == "A한B")
        #expect(!selection.text.contains("\u{1B}"))
    }

    @Test func invalidAndOutOfGridTargetsReturnNilWithoutSynthesizingText() {
        let snapshot = snapshot(["A", ""])
        let valid = TerminalGridPosition(row: 0, column: 0)
        let invalidTargets = [
            TerminalGridPosition(row: -1, column: 0),
            TerminalGridPosition(row: 0, column: -1),
            TerminalGridPosition(row: 0, column: 1),
            TerminalGridPosition(row: 1, column: 0),
            TerminalGridPosition(row: 2, column: 0),
            TerminalGridPosition(row: Int.max, column: Int.max),
        ]

        for target in invalidTargets {
            #expect(TerminalSelection(snapshot: snapshot, anchor: valid, focus: target) == nil)
            #expect(TerminalSelection(snapshot: snapshot, anchor: target, focus: valid) == nil)
        }
    }

    @Test func directRangeEndingBeyondSnapshotReturnsNil() {
        let extraction: String? = snapshot(["A"]).text(in: TerminalTextRange(
            start: TerminalGridPosition(row: 0, column: 0),
            end: TerminalGridPosition(row: 1, column: 0)
        ))

        #expect(extraction == nil)
    }

    @Test func directRangeStartingBeyondSnapshotReturnsNil() {
        let extraction: String? = snapshot(["A"]).text(in: TerminalTextRange(
            start: TerminalGridPosition(row: 1, column: 0),
            end: TerminalGridPosition(row: 1, column: 0)
        ))

        #expect(extraction == nil)
    }

    @Test func directRangesWithNegativePositionsReturnNil() {
        let snapshot = snapshot(["A"])
        let ranges = [
            TerminalTextRange(
                start: TerminalGridPosition(row: -1, column: 0),
                end: TerminalGridPosition(row: 0, column: 0)
            ),
            TerminalTextRange(
                start: TerminalGridPosition(row: 0, column: -1),
                end: TerminalGridPosition(row: 0, column: 0)
            ),
        ]

        for range in ranges {
            let extraction: String? = snapshot.text(in: range)
            #expect(extraction == nil)
        }
    }

    @Test func directRangeAgainstEmptySnapshotReturnsNil() {
        let extraction: String? = snapshot([]).text(in: TerminalTextRange(
            start: TerminalGridPosition(row: 0, column: 0),
            end: TerminalGridPosition(row: 0, column: 0)
        ))

        #expect(extraction == nil)
    }

    @Test func directRangeWithColumnBeyondRowWidthReturnsNil() {
        let extraction: String? = snapshot(["A"]).text(in: TerminalTextRange(
            start: TerminalGridPosition(row: 0, column: 1),
            end: TerminalGridPosition(row: 0, column: 1)
        ))

        #expect(extraction == nil)
    }

    @Test func reversedMalformedDirectRangeReturnsNilAfterNormalization() {
        let range = TerminalTextRange(
            start: TerminalGridPosition(row: 2, column: 0),
            end: TerminalGridPosition(row: 0, column: 0)
        )
        let extraction: String? = snapshot(["A"]).text(in: range)

        #expect(range.start == TerminalGridPosition(row: 0, column: 0))
        #expect(range.end == TerminalGridPosition(row: 2, column: 0))
        #expect(extraction == nil)
    }

    @Test func snapshotRemainsStableAfterTheGridChanges() throws {
        var grid = CellGrid(cols: 4, rows: 1)
        grid.replaceRow(0, raw: "A한B")
        let immutableSnapshot = TerminalSelectionSnapshot(renderRows: grid.renderRows)
        grid.replaceRow(0, raw: "changed")

        let selection = try #require(TerminalSelection(
            snapshot: immutableSnapshot,
            anchor: TerminalGridPosition(row: 0, column: 3),
            focus: TerminalGridPosition(row: 0, column: 1)
        ))
        #expect(selection.text == "한B")
        #expect(grid.renderRows[0].plainText == "changed")
    }

    @Test func reverseCJKModuleDriverObservable() throws {
        let selection = try #require(TerminalSelection(
            snapshot: snapshot(["A한B"]),
            anchor: TerminalGridPosition(row: 0, column: 2),
            focus: TerminalGridPosition(row: 0, column: 1)
        ))

        #expect(selection.text == "한")
        print("TASK4_DRIVER_TEXT=\(selection.text)")
    }

    private func renderRow(_ raw: String) -> TerminalRenderRow {
        TerminalRenderRow(cells: ANSIParser.parse(raw, base: .default))
    }

    private func snapshot(_ rawRows: [String], cols: Int = 80) -> TerminalSelectionSnapshot {
        var grid = CellGrid(cols: cols, rows: rawRows.count)
        for (index, raw) in rawRows.enumerated() {
            grid.replaceRow(index, raw: raw)
        }
        return TerminalSelectionSnapshot(renderRows: grid.renderRows)
    }
}
