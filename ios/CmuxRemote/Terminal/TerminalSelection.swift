struct TerminalSelection: Equatable, Sendable {
    let snapshot: TerminalSelectionSnapshot
    let anchor: TerminalGridPosition
    let focus: TerminalGridPosition

    init?(
        snapshot: TerminalSelectionSnapshot,
        anchor: TerminalGridPosition,
        focus: TerminalGridPosition
    ) {
        guard snapshot.contains(anchor), snapshot.contains(focus) else { return nil }
        self.snapshot = snapshot
        self.anchor = anchor
        self.focus = focus
    }

    var range: TerminalTextRange {
        TerminalTextRange(start: anchor, end: focus)
    }

    var text: String {
        snapshot.text(in: range) ?? ""
    }

    func updatingFocus(to focus: TerminalGridPosition) -> TerminalSelection? {
        TerminalSelection(snapshot: snapshot, anchor: anchor, focus: focus)
    }
}
