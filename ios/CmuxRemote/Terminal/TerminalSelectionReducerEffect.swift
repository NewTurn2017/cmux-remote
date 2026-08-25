/// Exposes reducer output that an integration layer may apply to the system.
enum TerminalSelectionReducerEffect: Equatable, Sendable {
    case copyText(String)
}
