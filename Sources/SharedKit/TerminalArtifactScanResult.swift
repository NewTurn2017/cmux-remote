import Foundation

public struct TerminalArtifactScanResult: Codable, Sendable, Equatable {
    /// Authorization generation used by all returned artifacts.
    public var generation: Int
    /// Ordered terminal-visible artifacts.
    public var artifacts: [TerminalArtifact]

    /// Creates a scan result.
    public init(generation: Int, artifacts: [TerminalArtifact]) {
        self.generation = generation; self.artifacts = artifacts
    }
}

/// Parameters for `terminal.artifact.stat`.
