import Foundation

public struct TerminalArtifactScanRequest: Codable, Sendable, Equatable {
    /// Workspace containing the terminal surface.
    public var workspaceId: String
    /// Terminal surface to inspect.
    public var surfaceId: String

    /// Creates an artifact scan request.
    public init(workspaceId: String, surfaceId: String) {
        self.workspaceId = workspaceId; self.surfaceId = surfaceId
    }
    private enum CodingKeys: String, CodingKey {
        case workspaceId, surfaceId
    }
}

/// One terminal-visible artifact authorized for subsequent operations.
