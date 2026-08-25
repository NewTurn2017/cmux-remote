import Foundation
import Testing
import SharedKit
@testable import CMUXClient

@Suite("CMUXRenderGrid")
struct CMUXRenderGridTests {
    @Test func fixtureDecodePreservesReplayMetadataAndAllTypedDTOs() throws {
        let replay = try SharedKitJSON.snakeCaseDecoder.decode(
            CMUXTerminalReplayRaw.self,
            from: RenderGridTestSupport.fixtureData()
        )
        let grid = replay.renderGrid

        #expect(replay.columns == 18)
        #expect(replay.rows == 3)
        #expect(replay.sequence == 27)
        #expect(replay.surfaceID == "surface-grid")
        #expect(replay.workspaceID == "workspace-grid")
        #expect(grid.format == "cmux.render-grid.v1")
        #expect(grid.columns == 18)
        #expect(grid.rows == 3)
        #expect(grid.cursor == CMUXRenderGridCursor(
            row: 2,
            column: 4,
            visible: true,
            blinking: false,
            style: .block
        ))
        #expect(grid.renderEpoch == CMUXRenderEpoch(rawValue: "00000000-0000-4000-8000-000000000027"))
        #expect(grid.renderRevision == CMUXRenderRevision(rawValue: 4))
        #expect(grid.styles.count == 34)
        #expect(grid.rowSpans.count == 3)
        #expect(grid.scrollbackRows == 2)
        #expect(grid.scrollbackSpans.count == 2)
        #expect(grid.styles.first { $0.id == 3 }?.background == "#283228")
        #expect(grid.terminalTheme?.background == "#101820")
        #expect(grid.terminalConfigTheme?.foreground == "#eaeaea")
        #expect(grid.terminalThemeRevision == 9)
        #expect(grid.historyRows == 12)
        #expect(grid.rowSpaceRevision == 7)
    }

    @Test func malformedFormatDimensionsCursorStyleAndSpanBoundsThrowTypedErrors() {
        let cases: [(Data, CMUXRenderGridError)] = [
            (
                RenderGridTestSupport.responseJSON(format: "cmux.render-grid.v0"),
                .invalidFormat("cmux.render-grid.v0")
            ),
            (
                RenderGridTestSupport.responseJSON(columns: 0),
                .invalidDimensions(columns: 0, rows: 2)
            ),
            (
                RenderGridTestSupport.responseJSON(rows: 0),
                .invalidDimensions(columns: 8, rows: 0)
            ),
            (
                RenderGridTestSupport.responseJSON(cursorRow: 2),
                .invalidCursor(row: 2, column: 0)
            ),
            (
                RenderGridTestSupport.responseJSON(cursorColumn: 8),
                .invalidCursor(row: 1, column: 8)
            ),
            (
                RenderGridTestSupport.responseJSON(
                    rowSpans: #"[{"row":0,"column":0,"style_id":99,"text":"x"}]"#
                ),
                .invalidStyleID(99)
            ),
            (
                RenderGridTestSupport.responseJSON(
                    rowSpans: #"[{"row":2,"column":0,"style_id":0,"text":"x"}]"#
                ),
                .invalidRow(2)
            ),
            (
                RenderGridTestSupport.responseJSON(
                    rowSpans: #"[{"row":0,"column":8,"style_id":0,"text":"x"}]"#
                ),
                .invalidColumn(8)
            ),
            (
                RenderGridTestSupport.responseJSON(
                    rowSpans: #"[{"row":0,"column":-1,"style_id":0,"text":"x"}]"#
                ),
                .invalidColumn(-1)
            ),
            (
                RenderGridTestSupport.responseJSON(
                    rowSpans: #"[{"row":0,"column":7,"style_id":0,"text":"xx","cell_width":2}]"#
                ),
                .invalidSpanWidth(row: 0, column: 7, width: 2, columns: 8)
            ),
            (
                RenderGridTestSupport.responseJSON(
                    rowSpans: #"[{"row":0,"column":0,"style_id":0,"text":"x","cell_width":0}]"#
                ),
                .invalidSpanWidth(row: 0, column: 0, width: 0, columns: 8)
            ),
            (
                RenderGridTestSupport.responseJSON(
                    rowSpans: #"[{"row":0,"column":0,"style_id":0,"text":"x","cell_width":9223372036854775807}]"#
                ),
                .invalidSpanWidth(row: 0, column: 0, width: Int.max, columns: 8)
            ),
            (
                RenderGridTestSupport.responseJSON(
                    rowSpans: #"[{"row":0,"column":0,"style_id":0,"text":"xx","cell_width":2},{"row":0,"column":1,"style_id":0,"text":"y","cell_width":1}]"#
                ),
                .invalidSpanWidth(row: 0, column: 1, width: 1, columns: 8)
            ),
            (
                RenderGridTestSupport.responseJSON(
                    scrollbackRows: 1,
                    scrollbackSpans: #"[{"row":1,"column":0,"style_id":0,"text":"x"}]"#
                ),
                .invalidRow(1)
            ),
        ]

        for (data, expected) in cases {
            do {
                _ = try RenderGridTestSupport.decode(data)
                Issue.record("expected \(expected)")
            } catch let error as CMUXRenderGridError {
                #expect(error == expected)
            } catch {
                Issue.record("expected \(expected), got \(error)")
            }
        }
    }

    @Test func missingOptionalFrameFieldsUseContractDefaults() throws {
        let raw = try RenderGridTestSupport.decode(RenderGridTestSupport.responseJSON())
        let grid = try #require(raw.renderGrid)

        #expect(grid.full)
        #expect(grid.clearedRows.isEmpty)
        #expect(grid.activeScreen == .primary)
        #expect(grid.modes.isEmpty)
        #expect(grid.anchor == .viewport)
        #expect(grid.scrolledRows == 0)
        #expect(grid.historyRows == nil)
        #expect(grid.rowSpaceRevision == nil)
        #expect(grid.terminalTheme == nil)
    }

    @Test func cjkFallbackWidthUsesTerminalColumnsAndCellWidthIsSpanTotal() throws {
        let data = RenderGridTestSupport.responseJSON(
            columns: 6,
            rows: 1,
            cursorRow: 0,
            rowSpans: #"[{"row":0,"column":0,"style_id":0,"text":"A한B"},{"row":0,"column":4,"style_id":0,"text":"Z","cell_width":1}]"#
        )
        let raw = try RenderGridTestSupport.decode(data)
        let spans = try #require(raw.renderGrid?.rowSpans)

        #expect(spans[0].gridCellWidth == 4)
        #expect(spans[1].gridCellWidth == 1)
        #expect(RenderGridTestSupport.visibleText(raw.toScreen(rev: 1).rows[0]) == "A한BZ")
    }

    @Test func bareSunFallbackWidthAllowsAnAdjacentColumnOneSpan() throws {
        let data = RenderGridTestSupport.responseJSON(
            columns: 3,
            rows: 1,
            cursorRow: 0,
            rowSpans: #"[{"row":0,"column":0,"style_id":0,"text":"☀"},{"row":0,"column":1,"style_id":0,"text":"X"}]"#
        )
        let raw = try RenderGridTestSupport.decode(data)
        let spans = try #require(raw.renderGrid?.rowSpans)

        #expect(spans.map(\.gridCellWidth) == [1, 1])
        #expect(RenderGridTestSupport.visibleText(raw.toScreen(rev: 0).rows[0]) == "☀X")
    }

    @Test func fallbackWidthMatchesUpstreamBoundariesEmojiCJKAndCombiningRules() {
        #expect("☀".cmuxTerminalCellWidth == 1)
        #expect("☀️".cmuxTerminalCellWidth == 2)
        #expect("⌙".cmuxTerminalCellWidth == 1) // U+2319: immediately before first emoji-wide boundary.
        #expect("⌚".cmuxTerminalCellWidth == 2) // U+231A: first emoji-wide boundary.
        #expect("✿".cmuxTerminalCellWidth == 1) // U+273F: ambiguous, but not producer-wide.
        #expect("➿".cmuxTerminalCellWidth == 2) // U+27BF: explicitly producer-wide.
        #expect("한".cmuxTerminalCellWidth == 2)
        #expect("😀".cmuxTerminalCellWidth == 2)
        #expect("e\u{0301}".cmuxTerminalCellWidth == 1)
        #expect("\u{0301}".cmuxTerminalCellWidth == 0)
        #expect("\u{200B}".cmuxTerminalCellWidth == 0)
        #expect("\u{FE0F}".cmuxTerminalCellWidth == 0)
    }

    @Test func explicitCellWidthRemainsAuthoritativeSpanTotalWidth() throws {
        let data = RenderGridTestSupport.responseJSON(
            columns: 4,
            rows: 1,
            cursorRow: 0,
            rowSpans: #"[{"row":0,"column":0,"style_id":0,"text":"☀","cell_width":2},{"row":0,"column":2,"style_id":0,"text":"X","cell_width":1}]"#
        )
        let raw = try RenderGridTestSupport.decode(data)
        let spans = try #require(raw.renderGrid?.rowSpans)

        #expect(spans.map(\.gridCellWidth) == [2, 1])
        #expect(RenderGridTestSupport.visibleText(raw.toScreen(rev: 0).rows[0]) == "☀X")
    }

    @Test func legacyPlainTextTranslationIsByteForByteUnchanged() throws {
        let data = Data(#"{"text":"hello\nworld!!\nfoo"}"#.utf8)
        let raw = try RenderGridTestSupport.decode(data)

        #expect(raw.renderGrid == nil)
        #expect(raw.toScreen(rev: 7) == Screen(
            rev: 7,
            rows: ["hello", "world!!", "foo"],
            cols: 7,
            cursor: CursorPos(x: 0, y: 0)
        ))
    }
}
