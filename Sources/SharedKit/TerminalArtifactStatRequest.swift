import Foundation

public struct TerminalArtifactStatRequest: Codable, Sendable, Equatable {
    /// Opaque authorization identifier.
    public var artifactId: String
    /// Creates a stat request.
    public init(artifactId: String) { self.artifactId = artifactId }
    private enum CodingKeys: String, CodingKey { case artifactId }
}

/// Metadata returned by `terminal.artifact.stat`.
