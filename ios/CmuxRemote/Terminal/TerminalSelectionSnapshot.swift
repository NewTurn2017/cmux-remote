struct TerminalSelectionSnapshot: Equatable, Sendable {
    let rows: [TerminalSelectionRow]

    init(rows: [TerminalSelectionRow]) {
        self.rows = rows
    }

    init(renderRows: [TerminalRenderRow]) {
        self.rows = renderRows.map(\.selectionRow)
    }

    var isWellFormed: Bool {
        rows.allSatisfy(\.isWellFormed)
    }

    func contains(_ position: TerminalGridPosition) -> Bool {
        guard rows.indices.contains(position.row) else { return false }
        return rows[position.row].contains(column: position.column)
    }

    func text(in range: TerminalTextRange) -> String? {
        guard contains(range.start), contains(range.end) else { return nil }

        return (range.start.row...range.end.row).map { rowIndex in
            let lowerBound = rowIndex == range.start.row ? range.start.column : nil
            let upperBound = rowIndex == range.end.row ? range.end.column : nil
            return rows[rowIndex].text(fromColumn: lowerBound, throughColumn: upperBound)
        }.joined(separator: "\n")
    }
}
