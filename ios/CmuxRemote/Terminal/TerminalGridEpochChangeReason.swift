/// Names the only terminal grid boundaries that advance a ``TerminalGridEpoch``.
enum TerminalGridEpochChangeReason: CaseIterable, Equatable, Sendable {
    case fullSnapshot
    case clear
    case reset
    case surfaceChanged
}
