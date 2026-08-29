/// Delivers terminal selection feedback at the UIKit boundary.
@MainActor
protocol TerminalSelectionFeedbackProviding: AnyObject {
    func provide(_ event: TerminalSelectionFeedbackEvent)
}
