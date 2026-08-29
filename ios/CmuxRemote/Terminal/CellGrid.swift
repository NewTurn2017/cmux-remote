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
        let renderRow = TerminalRenderRow(cells: cells, maximumColumns: cols)
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

    public init(cells: [ANSICell], maximumColumns: Int? = nil) {
        var runs: [TerminalRenderRun] = []
        var plainText = ""
        var column = 0
        var widths = cells.map { TerminalCellWidth.columns(for: $0.character) }
        var authoritativeStarts: [Int: Int] = [:]
        var metadataIndex = 0
        var projectedColumn = 0

        while metadataIndex < cells.count {
            let cell = cells[metadataIndex]
            guard let sourceColumn = cell.sourceColumn,
                  let sourceWidth = cell.sourceCellWidth,
                  let scalarCount = cell.sourceScalarCount,
                  scalarCount > 0,
                  scalarCount <= cells.count - metadataIndex,
                  sourceColumn == projectedColumn,
                  sourceWidth <= (maximumColumns.map { $0 - sourceColumn } ?? Int.max)
            else {
                projectedColumn += widths[metadataIndex]
                metadataIndex += 1
                continue
            }

            let sourceRange = metadataIndex..<(metadataIndex + scalarCount)
            let fallbackWidths = sourceRange.map { widths[$0] }
            var difference = sourceWidth - sourceRange.reduce(0) { $0 + widths[$1] }
            if difference < 0 {
                for index in sourceRange where difference < 0 && widths[index] > 1 {
                    let reduction = min(widths[index] - 1, -difference)
                    widths[index] -= reduction
                    difference += reduction
                }
            } else if difference > 0 {
                for index in sourceRange where difference > 0 && widths[index] > 0 {
                    let addition = min(max(0, 2 - widths[index]), difference)
                    widths[index] += addition
                    difference -= addition
                }
            }

            guard difference == 0 else {
                for (index, fallbackWidth) in zip(sourceRange, fallbackWidths) {
                    widths[index] = fallbackWidth
                }
                projectedColumn += widths[metadataIndex]
                metadataIndex += 1
                continue
            }

            authoritativeStarts[metadataIndex] = sourceColumn
            projectedColumn = sourceColumn + sourceWidth
            metadataIndex += scalarCount
        }

        for (index, cell) in cells.enumerated() {
            let startsAuthoritativeSpan = authoritativeStarts[index] != nil
            if let sourceColumn = authoritativeStarts[index] {
                column = sourceColumn
            }
            let cellColumns = widths[index]
            let displayText = TerminalGlyph.textStyleString(for: cell.character)
            plainText.append(String(cell.character))

            if cellColumns == 0, let last = runs.indices.last, runs[last].attr == cell.attr {
                runs[last].text.append(displayText)
            } else if cellColumns == 1,
                      !startsAuthoritativeSpan,
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

        self.init(runs: runs, columns: column, plainText: plainText)
    }

    public init(runs: [TerminalRenderRun], columns: Int, plainText: String) {
        self.runs = runs
        self.columns = columns
        self.plainText = plainText
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
