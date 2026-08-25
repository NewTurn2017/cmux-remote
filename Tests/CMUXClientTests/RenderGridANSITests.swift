import Foundation
import Testing
import SharedKit
import TerminalANSIParserTestSupport
@testable import CMUXClient

@Suite("RenderGridANSI")
struct RenderGridANSITests {
    @Test func fixtureUsesCanonicalCombinedTruecolorAndScrollbackViewportOrder() throws {
        let raw = try RenderGridTestSupport.decode(RenderGridTestSupport.fixtureData())
        let screen = raw.toScreen(rev: 12)

        #expect(screen.rev == 12)
        #expect(screen.cols == 18)
        #expect(screen.rows.count == 5)
        #expect(screen.rows.map(RenderGridTestSupport.visibleText) == [
            "history 0", "history 1", "GREEN BLOCK", "styled  ", "A한B",
        ])
        #expect(screen.rows[2].contains("\u{1B}[38;2;234;234;234;48;2;40;50;40m"))
        #expect(screen.rows.allSatisfy { $0.hasSuffix(RenderGridTestSupport.reset) })
    }

    @Test func defaultsInverseAndSupportedFlagsResolveToOneCanonicalSGR() throws {
        let styles = #"""
        [
          {"id":0,"foreground_source":"default","background_source":"default"},
          {"id":1,"foreground":"#010203","background":"#040506","foreground_source":"rgb","background_source":"rgb","bold":true,"faint":true,"italic":true,"underline":true,"blink":true,"inverse":true,"invisible":true,"strikethrough":true,"overline":true}
        ]
        """#
        let spans = #"""
        [
          {"row":0,"column":0,"style_id":0,"text":"D"},
          {"row":0,"column":1,"style_id":1,"text":"I"}
        ]
        """#
        let raw = try RenderGridTestSupport.decode(RenderGridTestSupport.responseJSON(
            rows: 1,
            cursorRow: 0,
            styles: styles,
            rowSpans: spans
        ))

        #expect(raw.toScreen(rev: 0).rows == [
            "\u{1B}[38;2;234;234;234;48;2;16;24;32mD" +
                "\u{1B}[1;4;38;2;4;5;6;48;2;1;2;3mI" +
                RenderGridTestSupport.reset,
        ])
    }

    @Test func boldThenPlainDisablesBoldForThePlainCell() throws {
        let (row, cells) = try Self.parsedTransitionRow(
            spans: #"[{"row":0,"column":0,"style_id":1,"text":"B"},{"row":0,"column":1,"style_id":0,"text":"P"}]"#
        )

        #expect(cells.map(\.character) == ["B", "P"])
        #expect(cells.map(\.attr.bold) == [true, false])
        #expect(cells.map(\.attr.underline) == [false, false])
        #expect(row.contains("B\u{1B}[22;38;2;234;234;234;48;2;16;24;32mP"))
    }

    @Test func underlineThenPlainDisablesUnderlineForThePlainCell() throws {
        let (row, cells) = try Self.parsedTransitionRow(
            spans: #"[{"row":0,"column":0,"style_id":2,"text":"U"},{"row":0,"column":1,"style_id":0,"text":"P"}]"#
        )

        #expect(cells.map(\.character) == ["U", "P"])
        #expect(cells.map(\.attr.bold) == [false, false])
        #expect(cells.map(\.attr.underline) == [true, false])
        #expect(row.contains("U\u{1B}[24;38;2;234;234;234;48;2;16;24;32mP"))
    }

    @Test func boldUnderlineThenPlainDisablesBothForThePlainCell() throws {
        let (row, cells) = try Self.parsedTransitionRow(
            spans: #"[{"row":0,"column":0,"style_id":3,"text":"X"},{"row":0,"column":1,"style_id":0,"text":"P"}]"#
        )

        #expect(cells.map(\.character) == ["X", "P"])
        #expect(cells.map(\.attr.bold) == [true, false])
        #expect(cells.map(\.attr.underline) == [true, false])
        #expect(row.contains("X\u{1B}[22;24;38;2;234;234;234;48;2;16;24;32mP"))
    }

    @Test func mixedBoldUnderlineTransitionsHaveExactParserAttributes() throws {
        let (row, cells) = try Self.parsedTransitionRow(
            spans: #"[{"row":0,"column":0,"style_id":1,"text":"B"},{"row":0,"column":1,"style_id":2,"text":"U"},{"row":0,"column":2,"style_id":3,"text":"X"},{"row":0,"column":3,"style_id":0,"text":"P"}]"#
        )

        #expect(cells.map(\.character) == ["B", "U", "X", "P"])
        #expect(cells.map(\.attr.bold) == [true, false, true, false])
        #expect(cells.map(\.attr.underline) == [false, true, true, false])
        #expect(row.hasPrefix("\u{1B}[1;38;2;234;234;234;48;2;16;24;32mB"))
        #expect(row.contains("B\u{1B}[22;4;38;2;234;234;234;48;2;16;24;32mU"))
        #expect(row.contains("U\u{1B}[1;38;2;234;234;234;48;2;16;24;32mX"))
        #expect(row.contains("X\u{1B}[22;24;38;2;234;234;234;48;2;16;24;32mP"))
        #expect(row.hasSuffix(RenderGridTestSupport.reset))
    }

    @Test func explicitStyledAndTrailingSpacesSurviveWithoutGridPadding() throws {
        let styles = #"""
        [
          {"id":0,"foreground_source":"default","background_source":"default"},
          {"id":2,"foreground":"#abcdef","background":"#112233"}
        ]
        """#
        let spans = #"""
        [
          {"row":0,"column":0,"style_id":2,"text":"A ","cell_width":2},
          {"row":0,"column":2,"style_id":0,"text":" ","cell_width":1}
        ]
        """#
        let raw = try RenderGridTestSupport.decode(RenderGridTestSupport.responseJSON(
            columns: 12,
            rows: 1,
            cursorRow: 0,
            styles: styles,
            rowSpans: spans
        ))
        let row = raw.toScreen(rev: 0).rows[0]

        #expect(RenderGridTestSupport.visibleText(row) == "A  ")
        #expect(row.contains("\u{1B}[38;2;171;205;239;48;2;17;34;51mA "))
        #expect(!RenderGridTestSupport.visibleText(row).hasSuffix(String(repeating: " ", count: 10)))
    }

    @Test func terminalColumnGapsUseExplicitDefaultsButRowsAreNeverRightPadded() throws {
        let spans = #"[{"row":0,"column":3,"style_id":0,"text":"X","cell_width":1}]"#
        let raw = try RenderGridTestSupport.decode(RenderGridTestSupport.responseJSON(
            columns: 8,
            rows: 1,
            cursorRow: 0,
            rowSpans: spans
        ))
        let row = raw.toScreen(rev: 0).rows[0]

        #expect(RenderGridTestSupport.visibleText(row) == "   X")
        #expect(row.hasPrefix("\u{1B}[38;2;234;234;234;48;2;16;24;32m   "))
        #expect(row.hasSuffix("X" + RenderGridTestSupport.reset))
    }

    @Test func equalFramesProduceIdenticalUTF8RowsAndChecksums() throws {
        let data = try RenderGridTestSupport.fixtureData()
        let first = try RenderGridTestSupport.decode(data).toScreen(rev: 1)
        let second = try RenderGridTestSupport.decode(data).toScreen(rev: 1)

        #expect(first.rows.map { Data($0.utf8) } == second.rows.map { Data($0.utf8) })
        #expect(first.cursor == CursorPos(x: 4, y: 4))
        #expect(ScreenHasher.hash(first) == ScreenHasher.hash(second))
        #expect(ScreenHasher.hash(first) == "6a08ba07df30dbc8")
    }

    private static func parsedTransitionRow(spans: String) throws -> (String, [ANSICell]) {
        let styles = #"[{"id":0,"foreground_source":"default","background_source":"default"},{"id":1,"bold":true},{"id":2,"underline":true},{"id":3,"bold":true,"underline":true}]"#
        let raw = try RenderGridTestSupport.decode(RenderGridTestSupport.responseJSON(
            rows: 1,
            cursorRow: 0,
            styles: styles,
            rowSpans: spans
        ))
        let row = raw.toScreen(rev: 0).rows[0]
        return (row, ANSIParser.parse(row, base: .default))
    }

    @Test func eachRowEndsResetAndStartsWithAnExplicitEffectiveStyle() throws {
        let spans = #"""
        [
          {"row":0,"column":0,"style_id":0,"text":"one"},
          {"row":1,"column":0,"style_id":0,"text":"two"}
        ]
        """#
        let raw = try RenderGridTestSupport.decode(RenderGridTestSupport.responseJSON(rowSpans: spans))
        let rows = raw.toScreen(rev: 0).rows

        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.hasPrefix("\u{1B}[38;2;") })
        #expect(rows.allSatisfy { $0.hasSuffix(RenderGridTestSupport.reset) })
    }
}
