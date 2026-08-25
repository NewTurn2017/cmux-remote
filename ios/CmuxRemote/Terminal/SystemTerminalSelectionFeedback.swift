import UIKit

/// Delivers selection haptics and VoiceOver announcements through UIKit.
@MainActor
final class SystemTerminalSelectionFeedback: TerminalSelectionFeedbackProviding {
    func provide(_ event: TerminalSelectionFeedbackEvent) {
        switch event {
        case .selectionStarted:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            UIAccessibility.post(
                notification: .announcement,
                argument: String(localized: "Terminal selection started")
            )
        case .copyCompleted:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            UIAccessibility.post(
                notification: .announcement,
                argument: String(localized: "Terminal selection copied")
            )
        }
    }
}
