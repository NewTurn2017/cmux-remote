import Foundation

struct SystemTerminalArtifactClock: TerminalArtifactClock {
    func now() async -> Date { Date() }
}
