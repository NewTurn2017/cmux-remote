import XCTest
import SharedKit
@testable import CmuxRemote

final class TerminalVisualLayoutTests: XCTestCase {
    func testLongRowsWrapToTheViewportWithoutLosingAttributes() {
        let green = ANSIAttr(fg: .green, bg: .default, bold: false, underline: false)
        let cells = [
            ANSICell(character: "a", attr: .default),
            ANSICell(character: "b", attr: .default),
            ANSICell(character: "c", attr: green),
            ANSICell(character: "d", attr: green),
            ANSICell(character: "e", attr: green),
        ]

        let layout = TerminalVisualLayout.make(
            rows: [cells],
            cursor: CursorPos(x: 4, y: 0),
            wrappingAt: 3
        )

        XCTAssertEqual(layout.rows.map(\.plainText), ["abc", "de"])
        XCTAssertEqual(layout.rows[0].runs.last?.attr, green)
        XCTAssertEqual(layout.rows[1].runs.first?.attr, green)
        XCTAssertEqual(layout.cursor, CursorPos(x: 1, y: 1))
    }

    func testWideCharactersNeverSplitAcrossVisualRows() {
        let cells = ANSIParser.parse("A한B", base: .default)

        let layout = TerminalVisualLayout.make(
            rows: [cells],
            cursor: CursorPos(x: 0, y: 0),
            wrappingAt: 3
        )

        XCTAssertEqual(layout.rows.map(\.plainText), ["A한", "B"])
        XCTAssertEqual(layout.rows.map(\.columns), [3, 1])
    }
}
