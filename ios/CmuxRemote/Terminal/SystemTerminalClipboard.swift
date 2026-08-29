import UIKit

/// Writes explicit terminal copy actions to the iOS system pasteboard.
@MainActor
final class SystemTerminalClipboard: TerminalClipboardWriting {
    func write(_ text: String) {
        UIPasteboard.general.string = text
    }
}
