import Foundation
import SharedKit

public struct CellGrid: Equatable {
    public var rows: [[ANSICell]]
    public var rawRows: [String]
    public var renderRows: [TerminalRenderRow]
    public var cols: Int
    public var maxRenderedColumns: Int
    public var cursor: CursorPos = CursorPos(x: 0, y: 0)

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = Array(repeating: [], count: rows)
        self.rawRows = Array(repeating: "", count: rows)
        self.renderRows = Array(repeating: .empty, count: rows)
        self.maxRenderedColumns = 0
    }

    public mutating func replaceRow(_ y: Int, raw: String) {
        guard y >= 0 else { return }
        if y >= rows.count {
            let missing = y - rows.count + 1
            rows.append(contentsOf: Array(repeating: [], count: missing))
            rawRows.append(contentsOf: Array(repeating: "", count: missing))
            renderRows.append(contentsOf: Array(repeating: .empty, count: missing))
        }
        let oldColumns = renderRows[y].columns
        let cells = ANSIParser.parse(raw, base: .default)
        let renderRow = TerminalRenderRow(cells: cells)
        rows[y] = cells
        rawRows[y] = raw
        renderRows[y] = renderRow
        updateMaxRenderedColumns(oldColumns: oldColumns, newColumns: renderRow.columns)
    }

    public mutating func clear() {
        for index in rows.indices { rows[index] = [] }
        for index in rawRows.indices { rawRows[index] = "" }
        for index in renderRows.indices { renderRows[index] = .empty }
        maxRenderedColumns = 0
    }

    private mutating func updateMaxRenderedColumns(oldColumns: Int, newColumns: Int) {
        if newColumns >= maxRenderedColumns {
            maxRenderedColumns = newColumns
        } else if oldColumns == maxRenderedColumns {
            maxRenderedColumns = renderRows.map(\.columns).max() ?? 0
        }
    }
}

public struct TerminalRenderRow: Equatable {
    public static let empty = TerminalRenderRow(runs: [], columns: 0, plainText: "")

    public var runs: [TerminalRenderRun]
    public var columns: Int
    public var plainText: String
    let selectionRow: TerminalSelectionRow

    public init(cells: [ANSICell]) {
        var runs: [TerminalRenderRun] = []
        var spans: [TerminalColumnSpan] = []
        var plainText = ""
        var column = 0

        for cell in cells {
            let cellColumns = TerminalCellWidth.columns(for: cell.character)
            let sourceText = String(cell.character)
            let displayText = TerminalGlyph.textStyleString(for: cell.character)
            plainText.append(sourceText)

            if cellColumns == 0, let last = spans.indices.last {
                let previous = spans[last]
                spans[last] = TerminalColumnSpan(
                    columns: previous.columns,
                    text: previous.text + sourceText
                )
            } else if cellColumns > 0 {
                spans.append(TerminalColumnSpan(
                    columns: column..<(column + cellColumns),
                    text: sourceText
                ))
            }

            if cellColumns == 0, let last = runs.indices.last, runs[last].attr == cell.attr {
                runs[last].text.append(displayText)
            } else if cellColumns == 1,
                      let last = runs.indices.last,
                      runs[last].attr == cell.attr,
                      runs[last].canMergeAdjacentCells
            {
                runs[last].text.append(displayText)
                runs[last].columns += cellColumns
            } else {
                runs.append(TerminalRenderRun(
                    text: displayText,
                    attr: cell.attr,
                    startColumn: cellColumns == 0 ? max(column - 1, 0) : column,
                    columns: cellColumns,
                    canMergeAdjacentCells: cellColumns == 1
                ))
            }
            column += cellColumns
        }

        self.runs = runs
        self.columns = column
        self.plainText = plainText
        self.selectionRow = TerminalSelectionRow(spans: spans)
    }

    public init(runs: [TerminalRenderRun], columns: Int, plainText: String) {
        self.runs = runs
        self.columns = columns
        self.plainText = plainText
        self.selectionRow = .empty
    }
}

public struct TerminalRenderRun: Equatable {
    public var text: String
    public var attr: ANSIAttr
    public var startColumn: Int
    public var columns: Int
    public var canMergeAdjacentCells: Bool

    public init(
        text: String,
        attr: ANSIAttr,
        startColumn: Int,
        columns: Int,
        canMergeAdjacentCells: Bool = true
    ) {
        self.text = text
        self.attr = attr
        self.startColumn = startColumn
        self.columns = columns
        self.canMergeAdjacentCells = canMergeAdjacentCells
    }
}
