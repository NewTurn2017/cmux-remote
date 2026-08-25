/// Represents one gesture-independent terminal selection input.
enum TerminalSelectionReducerEvent: Equatable, Sendable {
    case recognizedPress(
        snapshot: TerminalSelectionSnapshot,
        at: TerminalGridPosition,
        epoch: TerminalGridEpoch
    )
    case move(to: TerminalGridPosition, epoch: TerminalGridEpoch)
    case reverse(to: TerminalGridPosition, epoch: TerminalGridEpoch)
    case end(epoch: TerminalGridEpoch)
    case cancel
    case copy(epoch: TerminalGridEpoch)
    case pinch
    case epochChanged(to: TerminalGridEpoch, reason: TerminalGridEpochChangeReason)
    case ordinaryRevisionChanged(to: Int)
}
