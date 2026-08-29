import Foundation

protocol TerminalArtifactClock: Sendable {
    func now() async -> Date
}
