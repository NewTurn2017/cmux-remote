import XCTest
import SharedKit
@testable import CmuxRemote

final class CellGridTests: XCTestCase {
    func testReplaceRowParsesAnsi() {
        var grid = CellGrid(cols: 80, rows: 3)
        grid.replaceRow(1, raw: "\u{1B}[31mok\u{1B}[0m")
        XCTAssertEqual(grid.rows[1].first?.character, "o")
        XCTAssertEqual(grid.rows[1].first?.attr.fg, .red)
    }

    func testClearEmpties() {
        var grid = CellGrid(cols: 10, rows: 2)
        grid.replaceRow(0, raw: "hi")
        grid.clear()
        XCTAssertEqual(grid.rows[0].count, 0)
    }
}
