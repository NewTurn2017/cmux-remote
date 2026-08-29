import Foundation

protocol TerminalArtifactFileMetadataApplying: Sendable {
    func secure(_ url: URL) async throws
}
