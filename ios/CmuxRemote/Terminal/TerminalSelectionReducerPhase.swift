/// Describes whether terminal selection is inactive, moving, or ready for an action.
enum TerminalSelectionReducerPhase: Equatable, Sendable {
    case idle
    case selecting
    case selected
}
