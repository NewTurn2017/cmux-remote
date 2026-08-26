import SharedKit
import Testing
@testable import CmuxRemote

@Suite("CellGridTests")
struct CellGridTests {
    @Test func replaceRowParsesANSI() {
        var grid = CellGrid(cols: 80, rows: 3)
        grid.replaceRow(1, raw: "\u{1B}[31mok\u{1B}[0m")
        #expect(grid.rows[1].first?.character == "o")
        #expect(grid.rows[1].first?.attr.fg == .red)
        #expect(grid.rawRows[1] == "\u{1B}[31mok\u{1B}[0m")
    }

    @Test func replaceRowPrecomputesRenderRuns() {
        var grid = CellGrid(cols: 80, rows: 1)
        grid.replaceRow(0, raw: "\u{1B}[32mhello\u{1B}[0m \u{1B}[38;5;202mworld")

        #expect(grid.renderRows[0].columns == 11)
        #expect(grid.maxRenderedColumns == 11)
        #expect(grid.renderRows[0].plainText == "hello world")
        #expect(grid.renderRows[0].runs.map(\.text) == ["hello", " ", "world"])
        #expect(grid.renderRows[0].runs[0].attr.fg == .green)
        #expect(grid.renderRows[0].runs[2].attr.fg == .indexed(202))
    }

    @Test func renderRunsPinWideGlyphsToColumns() {
        var grid = CellGrid(cols: 80, rows: 1)
        grid.replaceRow(0, raw: "A한B")

        let runs = grid.renderRows[0].runs
        #expect(runs.map(\.text) == ["A", "한", "B"])
        #expect(runs.map(\.startColumn) == [0, 1, 3])
        #expect(runs.map(\.columns) == [1, 2, 1])
        #expect(grid.renderRows[0].columns == 4)
    }

    @Test func maxRenderedColumnsShrinksWhenLongestRowIsReplaced() {
        var grid = CellGrid(cols: 80, rows: 2)
        grid.replaceRow(0, raw: "long")
        grid.replaceRow(1, raw: "xx")
        #expect(grid.maxRenderedColumns == 4)

        grid.replaceRow(0, raw: "y")

        #expect(grid.maxRenderedColumns == 2)
    }

    @Test func clearEmpties() {
        var grid = CellGrid(cols: 10, rows: 2)
        grid.replaceRow(0, raw: "hi")
        grid.clear()
        #expect(grid.rows[0].count == 0)
        #expect(grid.rawRows[0] == "")
        #expect(grid.renderRows[0].runs.count == 0)
        #expect(grid.maxRenderedColumns == 0)
    }
}
