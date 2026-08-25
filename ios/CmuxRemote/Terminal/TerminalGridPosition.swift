struct TerminalGridPosition: Equatable, Comparable, Sendable {
    let row: Int
    let column: Int

    init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    static func < (lhs: TerminalGridPosition, rhs: TerminalGridPosition) -> Bool {
        if lhs.row != rhs.row {
            return lhs.row < rhs.row
        }
        return lhs.column < rhs.column
    }
}
