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
            "0123456789ABCDEFG", "HIJKLMNOPQRSTUVWX", "GREEN BLOCK", "styled  ", "A한B",
        ])
        #expect(screen.rows[2].contains("\u{1B}[38;2;234;234;234;48;2;40;50;40m"))
        #expect(screen.rows.allSatisfy { $0.hasSuffix(RenderGridTestSupport.reset) })
    }

    @Test func fixtureReferencesAndRendersAll34StylesSemantically() throws {
        let raw = try RenderGridTestSupport.decode(RenderGridTestSupport.fixtureData())
        let grid = try #require(raw.renderGrid)
        let cells = raw.toScreen(rev: 0).rows.prefix(2).flatMap {
            ANSIParser.parse($0, base: .default)
        }

        #expect(grid.styles.map(\.id) == Array(0..<34))
        #expect(grid.scrollbackSpans.map(\.styleID) == Array(0..<34))
        #expect(String(cells.map(\.character)) == "0123456789ABCDEFGHIJKLMNOPQRSTUVWX")
        #expect(cells.count == 34)
        for id in 0..<34 {
            #expect(cells[id].attr == Self.expectedFixtureAttribute(styleID: id))
        }
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
        let changedStyle = try RenderGridTestSupport.decode(
            Self.fixtureData(data, changingForegroundOfStyle: 33, to: "#2261a1")
        ).toScreen(rev: 1)

        #expect(first.rows.map { Data($0.utf8) } == second.rows.map { Data($0.utf8) })
        #expect(first.cursor == CursorPos(x: 4, y: 4))
        #expect(ScreenHasher.hash(first) == ScreenHasher.hash(second))
        #expect(ScreenHasher.hash(first) == "8e3d7360eef5c104")
        #expect(
            first.rows.map(RenderGridTestSupport.visibleText)
                == changedStyle.rows.map(RenderGridTestSupport.visibleText)
        )
        #expect(first.rows.map { Data($0.utf8) } != changedStyle.rows.map { Data($0.utf8) })
        #expect(ScreenHasher.hash(first) != ScreenHasher.hash(changedStyle))
    }

    private static func fixtureData(
        _ data: Data,
        changingForegroundOfStyle styleID: Int,
        to foreground: String
    ) throws -> Data {
        var root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var grid = try #require(root["render_grid"] as? [String: Any])
        var styles = try #require(grid["styles"] as? [[String: Any]])
        let styleIndex = try #require(styles.firstIndex {
            ($0["id"] as? NSNumber)?.intValue == styleID
        })
        styles[styleIndex]["foreground"] = foreground
        grid["styles"] = styles
        root["render_grid"] = grid
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func expectedFixtureAttribute(styleID: Int) -> ANSIAttr {
        switch styleID {
        case 0:
            return ANSIAttr(
                fg: .rgb(234, 234, 234),
                bg: .rgb(16, 24, 32),
                bold: false,
                underline: false
            )
        case 3:
            return ANSIAttr(
                fg: .rgb(234, 234, 234),
                bg: .rgb(40, 50, 40),
                bold: false,
                underline: false
            )
        case 4:
            return ANSIAttr(
                fg: .rgb(1, 2, 3),
                bg: .rgb(4, 5, 6),
                bold: true,
                underline: true
            )
        default:
            let foreground = ANSIColor.rgb(
                UInt8(styleID),
                UInt8(64 + styleID),
                UInt8(128 + styleID)
            )
            let background = ANSIColor.rgb(
                UInt8(160 + styleID),
                UInt8(80 + styleID),
                UInt8(16 + styleID)
            )
            return ANSIAttr(
                fg: styleID.isMultiple(of: 5) ? background : foreground,
                bg: styleID.isMultiple(of: 5) ? foreground : background,
                bold: !styleID.isMultiple(of: 2),
                underline: styleID.isMultiple(of: 3)
            )
        }
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
