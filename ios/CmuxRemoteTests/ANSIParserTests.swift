import XCTest
@testable import CmuxRemote

final class ANSIParserTests: XCTestCase {
    func testPlainText() {
        let cells = ANSIParser.parse("hello", base: .default)
        XCTAssertEqual(cells.count, 5)
        XCTAssertEqual(cells.first?.character, "h")
        XCTAssertEqual(cells.first?.attr, .default)
    }

    func testColorThenReset() {
        let cells = ANSIParser.parse("\u{1B}[31mred\u{1B}[0mok", base: .default)
        XCTAssertEqual(cells.count, 5)
        XCTAssertEqual(cells[0].attr.fg, .red)
        XCTAssertEqual(cells[3].attr, .default)
    }

    func testBold() {
        let cells = ANSIParser.parse("\u{1B}[1mbold\u{1B}[0m", base: .default)
        XCTAssertTrue(cells[0].attr.bold)
        XCTAssertTrue(cells[3].attr.bold)
    }

    func testUnknownEscapeIsDropped() {
        let cells = ANSIParser.parse("\u{1B}[?25lhi", base: .default)
        XCTAssertEqual(cells.count, 2)
    }
}
