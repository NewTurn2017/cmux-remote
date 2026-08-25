/// Reduces terminal selection lifecycle events without gesture or clipboard dependencies.
struct TerminalSelectionReducer: Equatable, Sendable {
    private(set) var epoch: TerminalGridEpoch
    private(set) var revision: Int
    private(set) var phase: TerminalSelectionReducerPhase = .idle
    private(set) var selection: TerminalSelection?

    init(epoch: TerminalGridEpoch = .initial, revision: Int = 0) {
        self.epoch = epoch
        self.revision = max(0, revision)
    }

    @discardableResult
    mutating func reduce(
        _ event: TerminalSelectionReducerEvent
    ) -> TerminalSelectionReducerEffect? {
        switch event {
        case .recognizedPress(let snapshot, let position, let eventEpoch):
            guard eventEpoch == epoch,
                  snapshot.isWellFormed,
                  let selection = TerminalSelection(
                    snapshot: snapshot,
                    anchor: position,
                    focus: position
                  )
            else { return nil }
            self.selection = selection
            phase = .selecting

        case .move(let position, let eventEpoch),
             .reverse(let position, let eventEpoch):
            updateFocus(to: position, eventEpoch: eventEpoch)

        case .end(let eventEpoch):
            guard eventEpoch == epoch, phase == .selecting, selection != nil else { return nil }
            phase = .selected

        case .cancel, .pinch:
            clearSelection()

        case .copy(let eventEpoch):
            guard eventEpoch == epoch, phase == .selected, let text = selection?.text else {
                return nil
            }
            clearSelection()
            return .copyText(text)

        case .epochChanged(let newEpoch, _):
            guard newEpoch > epoch else { return nil }
            epoch = newEpoch
            revision = 0
            clearSelection()

        case .ordinaryRevisionChanged(let newRevision):
            guard newRevision >= revision else { return nil }
            revision = newRevision
        }

        return nil
    }

    private mutating func updateFocus(
        to position: TerminalGridPosition,
        eventEpoch: TerminalGridEpoch
    ) {
        guard eventEpoch == epoch,
              phase == .selecting,
              let updated = selection?.updatingFocus(to: position)
        else { return }
        selection = updated
    }

    private mutating func clearSelection() {
        selection = nil
        phase = .idle
    }
}
