import Foundation

/// Parameters for `surface.document.open`. The relay reads the file path from cmux, never from the client.
public struct SurfaceDocumentOpenRequest: Codable, Sendable, Equatable {
    /// Workspace containing the document surface.
    public var workspaceId: String
    /// Document surface to open.
    public var surfaceId: String

    /// Creates a document-open request.
    public init(workspaceId: String, surfaceId: String) {
        self.workspaceId = workspaceId; self.surfaceId = surfaceId
    }
    private enum CodingKeys: String, CodingKey {
        case workspaceId, surfaceId
    }
}
