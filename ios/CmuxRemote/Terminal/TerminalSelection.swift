struct TerminalSelection: Equatable, Sendable {
    enum Boundary: Equatable, Sendable {
        case start
        case end
    }

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

    func adjusting(
        _ boundary: Boundary,
        to position: TerminalGridPosition
    ) -> (selection: TerminalSelection, activeBoundary: Boundary)? {
        let fixedPosition: TerminalGridPosition
        let activeBoundary: Boundary
        let updatedRange: TerminalTextRange

        switch boundary {
        case .start:
            fixedPosition = range.end
            if position <= fixedPosition {
                activeBoundary = .start
                updatedRange = TerminalTextRange(start: position, end: fixedPosition)
            } else {
                activeBoundary = .end
                updatedRange = TerminalTextRange(start: fixedPosition, end: position)
            }
        case .end:
            fixedPosition = range.start
            if position >= fixedPosition {
                activeBoundary = .end
                updatedRange = TerminalTextRange(start: fixedPosition, end: position)
            } else {
                activeBoundary = .start
                updatedRange = TerminalTextRange(start: position, end: fixedPosition)
            }
        }

        guard let selection = TerminalSelection(
            snapshot: snapshot,
            anchor: updatedRange.start,
            focus: updatedRange.end
        ) else { return nil }
        return (selection, activeBoundary)
    }
}
