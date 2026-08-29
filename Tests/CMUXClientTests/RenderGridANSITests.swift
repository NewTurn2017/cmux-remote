import Foundation
import SharedKit
import Testing
@testable import CMUXClient

@Suite("RenderGridANSI")
struct RenderGridANSITests {
    @Test func fixtureUsesCanonicalTruecolorAndScrollbackViewportOrder() throws {
        let raw = try RenderGridTestSupport.decode(RenderGridTestSupport.fixtureData())
        let screen = raw.toScreen(rev: 12)

        #expect(screen.rev == 12)
        #expect(screen.cols == 18)
        #expect(screen.rows.count == 5)
        #expect(screen.rows.map(RenderGridTestSupport.visibleText) == [
            "0123456789ABCDEFG", "HIJKLMNOPQRSTUVWX", "GREEN BLOCK", "styled  ", "A한B",
        ])
        #expect(screen.rows[2].contains(
            "\u{1B}[38;2;234;234;234;48;2;40;50;40m" +
                "\u{1B}[?2026;0;11;11zGREEN BLOCK"
        ))
        #expect(screen.rows.allSatisfy { $0.hasSuffix(RenderGridTestSupport.reset) })
    }

    @Test func fixtureReferencesAll34StylesAndLocksTheirCanonicalBytes() throws {
        let raw = try RenderGridTestSupport.decode(RenderGridTestSupport.fixtureData())
        let grid = try #require(raw.renderGrid)
        let screen = raw.toScreen(rev: 1)

        #expect(grid.styles.map(\.id) == Array(0..<34))
        #expect(grid.scrollbackSpans.map(\.styleID) == Array(0..<34))
        #expect(ScreenHasher.hash(screen) == "dd1f8d3b36031621")
    }

    @Test func defaultsInverseBoldAndUnderlineUseOneCanonicalSGR() throws {
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

    @Test func boldAndUnderlineTransitionsAreExplicitlyDisabled() throws {
        let styles = #"[{"id":0,"foreground_source":"default","background_source":"default"},{"id":1,"bold":true},{"id":2,"underline":true},{"id":3,"bold":true,"underline":true}]"#
        let spans = #"[{"row":0,"column":0,"style_id":1,"text":"B"},{"row":0,"column":1,"style_id":2,"text":"U"},{"row":0,"column":2,"style_id":3,"text":"X"},{"row":0,"column":3,"style_id":0,"text":"P"}]"#
        let raw = try RenderGridTestSupport.decode(RenderGridTestSupport.responseJSON(
            rows: 1,
            cursorRow: 0,
            styles: styles,
            rowSpans: spans
        ))
        let row = raw.toScreen(rev: 0).rows[0]

        #expect(row.hasPrefix("\u{1B}[1;38;2;234;234;234;48;2;16;24;32mB"))
        #expect(row.contains("B\u{1B}[22;4;38;2;234;234;234;48;2;16;24;32mU"))
        #expect(row.contains("U\u{1B}[1;38;2;234;234;234;48;2;16;24;32mX"))
        #expect(row.contains("X\u{1B}[22;24;38;2;234;234;234;48;2;16;24;32mP"))
    }

    @Test func styledAndTrailingSpacesSurviveWithoutGridPadding() throws {
        let styles = ##"[{"id":0,"foreground_source":"default","background_source":"default"},{"id":2,"foreground":"#abcdef","background":"#112233"}]"##
        let spans = #"[{"row":0,"column":0,"style_id":2,"text":"A ","cell_width":2},{"row":0,"column":2,"style_id":0,"text":" ","cell_width":1}]"#
        let raw = try RenderGridTestSupport.decode(RenderGridTestSupport.responseJSON(
            columns: 12,
            rows: 1,
            cursorRow: 0,
            styles: styles,
            rowSpans: spans
        ))
        let row = raw.toScreen(rev: 0).rows[0]

        #expect(RenderGridTestSupport.visibleText(row) == "A  ")
        #expect(row.contains(
            "\u{1B}[38;2;171;205;239;48;2;17;34;51m" +
                "\u{1B}[?2026;0;2;2zA "
        ))
        #expect(!RenderGridTestSupport.visibleText(row).hasSuffix(String(repeating: " ", count: 10)))
    }

    @Test func terminalColumnGapsUseExplicitDefaultsWithoutRightPadding() throws {
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

    @Test func authoritativeSpanGeometrySurvivesInLegacyANSIText() throws {
        let spans = #"[{"row":0,"column":0,"style_id":0,"text":"☀","cell_width":1},{"row":0,"column":1,"style_id":0,"text":"X","cell_width":1}]"#
        let raw = try RenderGridTestSupport.decode(RenderGridTestSupport.responseJSON(
            columns: 2,
            rows: 1,
            cursorRow: 0,
            rowSpans: spans
        ))
        let row = raw.toScreen(rev: 0).rows[0]

        #expect(row.contains("\u{1B}[?2026;0;1;1z☀"))
        #expect(row.contains("\u{1B}[?2026;1;1;1zX"))
        #expect(RenderGridTestSupport.visibleText(row) == "☀X")
    }

    @Test func equalFramesProduceIdenticalRowsAndStyleChangesChangeChecksum() throws {
        let data = try RenderGridTestSupport.fixtureData()
        let first = try RenderGridTestSupport.decode(data).toScreen(rev: 1)
        let second = try RenderGridTestSupport.decode(data).toScreen(rev: 1)
        var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var grid = try #require(root["render_grid"] as? [String: Any])
        var styles = try #require(grid["styles"] as? [[String: Any]])
        let styleIndex = try #require(styles.firstIndex { ($0["id"] as? NSNumber)?.intValue == 33 })
        styles[styleIndex]["foreground"] = "#2261a1"
        grid["styles"] = styles
        root["render_grid"] = grid
        let changedData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let changed = try RenderGridTestSupport.decode(changedData).toScreen(rev: 1)

        #expect(first.rows.map { Data($0.utf8) } == second.rows.map { Data($0.utf8) })
        #expect(first.cursor == CursorPos(x: 4, y: 4))
        #expect(first.rows.map(RenderGridTestSupport.visibleText) == changed.rows.map(RenderGridTestSupport.visibleText))
        #expect(ScreenHasher.hash(first) != ScreenHasher.hash(changed))
    }
}
