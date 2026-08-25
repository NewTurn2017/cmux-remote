import Testing
import SharedKit
@testable import RelayCore

@Suite("ScreenFidelityManualDriverTests")
struct ScreenFidelityManualDriverTests {
    @Test func printsAuthoritativeSnapshotObservables() throws {
        let cjk = try ScreenFidelityTests.screen(
            columns: 4,
            rows: 1,
            cursorRow: 0,
            cursorColumn: 3,
            rowSpans: [[
                "row": 0,
                "column": 0,
                "style_id": 0,
                "text": "A한B",
                "cell_width": 4,
            ]]
        )
        let styleBefore = try ScreenFidelityTests.screen(
            background: "#283228",
            revision: 2,
            plainText: "PLAIN FALLBACK"
        )
        let styleAfter = try ScreenFidelityTests.screen(
            background: "#382838",
            revision: 2,
            plainText: "PLAIN FALLBACK"
        )
        let epochAfter = try ScreenFidelityTests.screen(
            epoch: "00000000-0000-4000-8000-000000000002",
            revision: 1
        )
        let geometryAfter = try ScreenFidelityTests.screen(columns: 13, revision: 3)
        let invisibleCursor = try ScreenFidelityTests.screen(cursorVisible: false).cursor
        let droppedCursor = try ScreenFidelityTests.screen(
            columns: 8,
            rows: 121,
            cursorRow: 0,
            rowSpans: [["row": 120, "column": 0, "style_id": 0, "text": "tail"]]
        ).cursor
        let caseBefore = try ScreenFidelityTests.screen(terminalForeground: "#abcdef")
        let caseAfter = try ScreenFidelityTests.screen(terminalForeground: "#ABCDEF", revision: 3)
        let retained = try Self.retainedScreen()
        var styleState = RowState()
        var epochState = RowState()
        var geometryState = RowState()
        var caseState = RowState()
        _ = styleState.ingest(snapshot: styleBefore)
        _ = epochState.ingest(snapshot: styleBefore)
        _ = geometryState.ingest(snapshot: styleBefore)
        _ = caseState.ingest(snapshot: caseBefore)
        let styleOps = styleState.ingest(snapshot: styleAfter)
        let epochOps = epochState.ingest(snapshot: epochAfter)
        let geometryOps = geometryState.ingest(snapshot: geometryAfter)
        let caseOps = caseState.ingest(snapshot: caseAfter)
        let beforeHash = ScreenHasher.rowHash(styleBefore.rows[0])
        let afterHash = ScreenHasher.rowHash(styleAfter.rows[0])
        let styledChecksum = ScreenHasher.hash(styleBefore)
        let checksumRowsAreStyled = styleBefore.rows[0].contains("\u{1B}[38;2;234;234;234;48;2;40;50;40m")
            && styleBefore.rows.allSatisfy { !$0.contains("PLAIN FALLBACK") }

        print("cols=\(cjk.cols)")
        print("cursor=x=\(cjk.cursor.x),y=\(cjk.cursor.y)")
        print("rowHash.before=\(beforeHash)")
        print("rowHash.after=\(afterHash)")
        print("diffOp=\(String(reflecting: styleOps.first))")
        print("epochFullReset=\(epochOps.first == .clear)")
        print("geometryFullReset=\(geometryOps.first == .clear)")
        print("retainedLines=\(retained.rows.count)")
        print("invisibleCursor=x=\(invisibleCursor.x),y=\(invisibleCursor.y)")
        print("droppedCursor=x=\(droppedCursor.x),y=\(droppedCursor.y)")
        print("caseOnlyThemeIdentityReset=\(caseOps.first == .clear)")
        print("styledChecksum=\(styledChecksum) styledRowsIdentical=\(checksumRowsAreStyled) plainFallbackUsed=false")

        #expect(cjk.cols == 4)
        #expect(cjk.cursor == CursorPos(x: 3, y: 0))
        #expect(beforeHash != afterHash)
        #expect(styleOps == [.row(y: 0, text: styleAfter.rows[0])])
        #expect(epochOps.first == .clear)
        #expect(geometryOps.first == .clear)
        #expect(retained.rows.count == 120)
        #expect(invisibleCursor == .hidden)
        #expect(droppedCursor == .hidden)
        #expect(caseOps.isEmpty)
        #expect(checksumRowsAreStyled)
    }

    static func retainedScreen() throws -> Screen {
        let scrollbackSpans: [[String: Any]] = (0..<125).map { row in
            ["row": row, "column": 0, "style_id": 0, "text": "history \(row)"]
        }
        return try ScreenFidelityTests.screen(
            columns: 16,
            rows: 2,
            cursorRow: 1,
            cursorColumn: 2,
            rowSpans: [
                ["row": 0, "column": 0, "style_id": 0, "text": "viewport 0"],
                ["row": 1, "column": 0, "style_id": 0, "text": "viewport 1"],
            ],
            scrollbackRows: 125,
            scrollbackSpans: scrollbackSpans,
            plainText: "PLAIN FALLBACK"
        )
    }
}
