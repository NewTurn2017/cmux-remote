import Foundation

public struct TerminalArtifactThumbnailRequest: Codable, Sendable, Equatable {
    /// Opaque authorization identifier.
    public var artifactId: String
    /// Requested maximum dimension in pixels.
    public var dimension: Int

    /// Creates a thumbnail request.
    public init(artifactId: String, dimension: Int = TerminalArtifactLimits.defaultThumbnailDimension) {
        self.artifactId = artifactId; self.dimension = dimension
    }
    private enum CodingKeys: String, CodingKey { case artifactId, dimension }

    /// Decodes and validates a thumbnail request.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.artifactId), let artifactId = try? c.decode(String.self, forKey: .artifactId), !artifactId.isEmpty else { throw RemoteProtocolError.missingField("artifact_id") }
        guard c.contains(.dimension), let dimension = try? c.decode(Int.self, forKey: .dimension), (64...TerminalArtifactLimits.maxThumbnailDimension).contains(dimension) else { throw RemoteProtocolError.invalidThumbnailDimension }
        self.init(artifactId: artifactId, dimension: dimension)
    }
}

/// A generated image thumbnail returned by `terminal.artifact.thumbnail`.
