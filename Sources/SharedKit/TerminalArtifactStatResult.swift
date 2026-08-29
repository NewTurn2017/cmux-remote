import Foundation

public struct TerminalArtifactStatResult: Codable, Sendable, Equatable {
    /// Opaque authorization identifier.
    public var artifactId: String
    /// Display filename.
    public var filename: String
    /// MIME type.
    public var mimeType: String
    /// Current file size.
    public var bytes: Int
    /// Revision checked by the relay.
    public var revision: String
    /// Image width when known.
    public var width: Int?
    /// Image height when known.
    public var height: Int?

    /// Creates artifact metadata.
    public init(artifactId: String, filename: String, mimeType: String, bytes: Int,
                revision: String, width: Int? = nil, height: Int? = nil) {
        self.artifactId = artifactId; self.filename = filename; self.mimeType = mimeType
        self.bytes = bytes; self.revision = revision; self.width = width; self.height = height
    }
    private enum CodingKeys: String, CodingKey {
        case artifactId, filename, mimeType, bytes, revision, width, height
    }
}

/// Parameters for `terminal.artifact.fetch`.
