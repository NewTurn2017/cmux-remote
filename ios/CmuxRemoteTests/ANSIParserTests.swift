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

    func testExtendedForegroundAndBackgroundColors() {
        let cells = ANSIParser.parse("\u{1B}[38;5;202;48;2;10;20;30mX", base: .default)
        XCTAssertEqual(cells.first?.attr.fg, .indexed(202))
        XCTAssertEqual(cells.first?.attr.bg, .rgb(10, 20, 30))
    }

    func testExactRGBForegroundAndBackgroundColors() {
        let cells = ANSIParser.parse("\u{1B}[38;2;125;207;255;48;2;157;124;216mX", base: .default)
        XCTAssertEqual(cells.first?.attr.fg, .rgb(125, 207, 255))
        XCTAssertEqual(cells.first?.attr.bg, .rgb(157, 124, 216))
    }

    func testBrightBackgroundColor() {
        let cells = ANSIParser.parse("\u{1B}[104mX", base: .default)
        XCTAssertEqual(cells.first?.attr.bg, .bright(.blue))
    }

    func testUnknownEscapeIsDropped() {
        let cells = ANSIParser.parse("\u{1B}[?25lhi", base: .default)
        XCTAssertEqual(cells.count, 2)
    }

    func testUnknownSGRCodeDoesNotHangAndPreservesText() {
        let cells = ANSIParser.parse("\u{1B}[999mX", base: .default)
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells.first?.character, "X")
        XCTAssertEqual(cells.first?.attr, .default)
    }

    func testPrivateProducerGeometryAnnotatesOnlyItsDeclaredScalarSpan() {
        let cells = ANSIParser.parse(
            "\u{1B}[?2026;3;1;1z☀\u{1B}[32mX",
            base: .default
        )

        XCTAssertEqual(cells.map(\.character), ["☀", "X"])
        XCTAssertEqual(cells[0].sourceColumn, 3)
        XCTAssertEqual(cells[0].sourceCellWidth, 1)
        XCTAssertEqual(cells[0].sourceScalarCount, 1)
        XCTAssertNil(cells[1].sourceColumn)
        XCTAssertEqual(cells[1].attr.fg, .green)
    }

    func testMalformedPrivateProducerGeometryDoesNotLeakToFollowingText() {
        let cells = ANSIParser.parse(
            "\u{1B}[?2026;0;1;2z☀\u{1B}[31mX",
            base: .default
        )

        XCTAssertEqual(cells.map(\.character), ["☀", "X"])
        XCTAssertTrue(cells.allSatisfy { $0.sourceColumn == nil })
        XCTAssertEqual(cells[1].attr.fg, .red)
    }
}
