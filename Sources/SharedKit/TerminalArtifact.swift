import Foundation

public struct TerminalArtifact: Codable, Sendable, Equatable, Identifiable {
    /// Opaque authorization identifier.
    public var artifactId: String
    /// Display filename without a canonical path.
    public var filename: String
    /// Deterministic MIME type.
    public var mimeType: String
    /// Current file size in bytes.
    public var bytes: Int
    /// Revision bound to the authorization.
    public var revision: String
    /// Whether the artifact is an image eligible for visual preview.
    public var isImage: Bool

    /// The artifact's opaque identifier.
    public var id: String { artifactId }

    /// Creates an authorized artifact description.
    public init(artifactId: String, filename: String, mimeType: String, bytes: Int,
                revision: String, isImage: Bool) {
        self.artifactId = artifactId; self.filename = filename; self.mimeType = mimeType
        self.bytes = bytes; self.revision = revision; self.isImage = isImage
    }
    private enum CodingKeys: String, CodingKey {
        case artifactId, filename, mimeType, bytes, revision, isImage
    }
}

/// Result for `terminal.artifact.scan`.
