import Foundation

public struct TerminalArtifactThumbnailResult: Codable, Sendable, Equatable {
    /// Opaque authorization identifier.
    public var artifactId: String
    /// Revision used to generate the thumbnail.
    public var revision: String
    /// Requested dimension.
    public var dimension: Int
    /// Actual pixel width.
    public var width: Int
    /// Actual pixel height.
    public var height: Int
    /// Thumbnail MIME type, normally `image/jpeg`.
    public var mimeType: String
    /// Canonical base64-encoded thumbnail bytes.
    public var dataBase64: String

    /// Creates a thumbnail response.
    public init(artifactId: String, revision: String, dimension: Int, width: Int, height: Int,
                mimeType: String, dataBase64: String) {
        self.artifactId = artifactId; self.revision = revision; self.dimension = dimension
        self.width = width; self.height = height; self.mimeType = mimeType; self.dataBase64 = dataBase64
    }
    /// Decodes and validates a thumbnail response.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.artifactId), let artifactId = try? c.decode(String.self, forKey: .artifactId), !artifactId.isEmpty else { throw RemoteProtocolError.missingField("artifact_id") }
        guard c.contains(.revision), let revision = try? c.decode(String.self, forKey: .revision), !revision.isEmpty else { throw RemoteProtocolError.missingField("revision") }
        guard c.contains(.dimension), let dimension = try? c.decode(Int.self, forKey: .dimension), (64...TerminalArtifactLimits.maxThumbnailDimension).contains(dimension) else { throw RemoteProtocolError.invalidThumbnailDimension }
        guard c.contains(.width), let width = try? c.decode(Int.self, forKey: .width), width > 0 else { throw RemoteProtocolError.invalidField("width") }
        guard c.contains(.height), let height = try? c.decode(Int.self, forKey: .height), height > 0 else { throw RemoteProtocolError.invalidField("height") }
        guard c.contains(.mimeType), let mimeType = try? c.decode(String.self, forKey: .mimeType), !mimeType.isEmpty else { throw RemoteProtocolError.missingField("mime_type") }
        guard c.contains(.dataBase64), let dataBase64 = try? c.decode(String.self, forKey: .dataBase64) else { throw RemoteProtocolError.missingField("data_base64") }
        self.init(artifactId: artifactId, revision: revision, dimension: dimension, width: width, height: height, mimeType: mimeType, dataBase64: dataBase64)
        _ = try decodedBytes()
    }

    /// Decodes the thumbnail bytes after enforcing the thumbnail-size limit.
    ///
    /// - Returns: The decoded thumbnail bytes.
    /// - Throws: ``RemoteProtocolError`` for malformed or oversized data.
    public func decodedBytes() throws -> Data {
        guard let data = Data(base64Encoded: dataBase64), data.base64EncodedString() == dataBase64 else { throw RemoteProtocolError.invalidBase64 }
        guard data.count <= TerminalArtifactLimits.maxThumbnailBytes else { throw RemoteProtocolError.chunkTooLarge(maxBytes: TerminalArtifactLimits.maxThumbnailBytes) }
        return data
    }

    private enum CodingKeys: String, CodingKey {
        case artifactId, revision, dimension, width, height, mimeType, dataBase64
    }
}
