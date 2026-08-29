/// Writes terminal selection text to a clipboard boundary.
@MainActor
protocol TerminalClipboardWriting: AnyObject {
    func write(_ text: String)
}
