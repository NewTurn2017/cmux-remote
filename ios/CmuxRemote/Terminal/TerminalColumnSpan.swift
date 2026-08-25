struct TerminalColumnSpan: Equatable, Sendable {
    let columns: Range<Int>
    let text: String

    init(columns: Range<Int>, text: String) {
        self.columns = columns
        self.text = text
    }

    func contains(column: Int) -> Bool {
        columns.contains(column)
    }
}
