import Foundation

protocol TerminalArtifactImageInspecting: Sendable {
    func dimensions(of url: URL) throws -> TerminalArtifactImageDimensions
}
