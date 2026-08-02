import XCTest
@testable import CmuxRemote

final class TerminalViewTests: XCTestCase {
    func testIPadUsesReadableDefaultFontWithoutChangingIPhoneDensity() {
        XCTAssertEqual(TerminalLayoutPolicy.defaultFontSize(isPad: true), 11)
        XCTAssertEqual(TerminalLayoutPolicy.defaultFontSize(isPad: false), 8)
    }

    func testBottomScrollPaddingMatchesFiveTerminalRows() {
        XCTAssertEqual(TerminalView.bottomScrollPaddingRows, 5)
        XCTAssertEqual(TerminalView.bottomScrollPadding(lineHeight: 10), 50)
    }
}
