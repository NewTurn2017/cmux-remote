import XCTest
@testable import CmuxRemote

final class TerminalGridLayoutTests: XCTestCase {
    private let cellWidth: CGFloat = 7
    private let lineHeight: CGFloat = 12

    func testMixedCJKRunFramesFollowTerminalColumns() {
        // Given
        var grid = CellGrid(cols: 4, rows: 1)
        grid.replaceRow(0, raw: "A한B")
        let layout = TerminalGridLayout(cellWidth: cellWidth, lineHeight: lineHeight)

        // When
        let frames = grid.renderRows[0].runs.map {
            layout.frame(startColumn: $0.startColumn, columns: $0.columns, row: 0)
        }

        // Then
        XCTAssertEqual(frames.map(\.minX), [0, 7, 21])
        XCTAssertEqual(frames.map(\.width), [7, 14, 7])
        assertAdjacentFramesDoNotOverlap(frames)
    }

    func testConsecutiveHangulRunFramesDoNotOverlap() {
        // Given
        var grid = CellGrid(cols: 8, rows: 1)
        grid.replaceRow(0, raw: "한글테스")
        let layout = TerminalGridLayout(cellWidth: cellWidth, lineHeight: lineHeight)

        // When
        let frames = grid.renderRows[0].runs.map {
            layout.frame(startColumn: $0.startColumn, columns: $0.columns, row: 0)
        }

        // Then
        XCTAssertEqual(frames.map(\.minX), [0, 14, 28, 42])
        XCTAssertEqual(frames.map(\.width), [14, 14, 14, 14])
        assertAdjacentFramesDoNotOverlap(frames)
    }

    func testWideGlyphAtRowEndOccupiesExactlyTwoCells() throws {
        // Given
        var grid = CellGrid(cols: 4, rows: 1)
        grid.replaceRow(0, raw: "AB한")
        let layout = TerminalGridLayout(cellWidth: cellWidth, lineHeight: lineHeight)

        // When
        let frames = grid.renderRows[0].runs.map {
            layout.frame(startColumn: $0.startColumn, columns: $0.columns, row: 0)
        }
        let wideFrame = try XCTUnwrap(frames.last)

        // Then
        XCTAssertEqual(wideFrame.minX, 2 * cellWidth)
        XCTAssertEqual(wideFrame.width, 2 * cellWidth)
        XCTAssertEqual(wideFrame.maxX, CGFloat(grid.cols) * cellWidth)
        assertAdjacentFramesDoNotOverlap(frames)
    }

    private func assertAdjacentFramesDoNotOverlap(
        _ frames: [CGRect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (current, next) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(current.maxX, next.minX, file: file, line: line)
        }
    }
}
