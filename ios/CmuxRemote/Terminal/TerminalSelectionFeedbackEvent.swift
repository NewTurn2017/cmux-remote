/// Identifies tactile and assistive feedback emitted by terminal selection.
enum TerminalSelectionFeedbackEvent: Equatable, Sendable {
    case selectionStarted
    case copyCompleted
}
