struct TerminalTextRange: Equatable, Sendable {
    let start: TerminalGridPosition
    let end: TerminalGridPosition

    init(start: TerminalGridPosition, end: TerminalGridPosition) {
        if start <= end {
            self.start = start
            self.end = end
        } else {
            self.start = end
            self.end = start
        }
    }
}
