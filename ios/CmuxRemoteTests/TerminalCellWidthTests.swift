import XCTest
@testable import CmuxRemote

final class TerminalCellWidthTests: XCTestCase {
    func testAsciiUsesSingleColumn() {
        XCTAssertEqual(TerminalCellWidth.columns(for: "A"), 1)
    }

    func testHangulUsesTwoColumns() {
        XCTAssertEqual(TerminalCellWidth.columns(for: "한"), 2)
        XCTAssertEqual(TerminalCellWidth.columns(for: "글"), 2)
    }

    func testCJKAndEmojiUseTwoColumns() {
        XCTAssertEqual(TerminalCellWidth.columns(for: "漢"), 2)
        XCTAssertEqual(TerminalCellWidth.columns(for: "✅"), 2)
    }

    func testCombiningMarkUsesNoAdditionalColumn() {
        let combiningAcute = Character("\u{0301}")
        XCTAssertEqual(TerminalCellWidth.columns(for: combiningAcute), 0)
    }

    func testRowWidthAddsWideGlyphColumns() {
        let row = ANSIParser.parse("A한B", base: .default)
        XCTAssertEqual(TerminalCellWidth.columns(for: row), 4)
    }
}
