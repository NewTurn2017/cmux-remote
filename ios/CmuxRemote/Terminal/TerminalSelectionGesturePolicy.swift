import CoreGraphics

/// Defines the gesture thresholds and scroll arbitration for terminal selection.
struct TerminalSelectionGesturePolicy {
    static let minimumPressDuration = 0.4
    static let maximumPressDistance: CGFloat = 12
    static let minimumDragDistance: CGFloat = 0

    static func allowsScrolling(during phase: TerminalSelectionReducerPhase) -> Bool {
        phase == .idle
    }
}
