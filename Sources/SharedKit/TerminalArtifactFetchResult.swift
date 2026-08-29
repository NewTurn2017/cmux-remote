import Foundation

public struct TerminalArtifactFetchResult: Codable, Sendable, Equatable {
    /// Opaque authorization identifier.
    public var artifactId: String
    /// Offset represented by `data_base64`.
    public var offset: Int
    /// Stable total file size.
    public var totalBytes: Int
    /// Revision used for this read.
    public var revision: String
    /// Canonical base64 bytes.
    public var dataBase64: String
    /// Whether this chunk reaches end of file.
    public var eof: Bool

    /// Creates a fetch response chunk.
    public init(artifactId: String, offset: Int, totalBytes: Int, revision: String,
                dataBase64: String, eof: Bool) {
        self.artifactId = artifactId; self.offset = offset; self.totalBytes = totalBytes
        self.revision = revision; self.dataBase64 = dataBase64; self.eof = eof
    }
    /// Decodes and validates a fetch response chunk.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.artifactId), let artifactId = try? c.decode(String.self, forKey: .artifactId), !artifactId.isEmpty else { throw RemoteProtocolError.missingField("artifact_id") }
        guard c.contains(.offset), let offset = try? c.decode(Int.self, forKey: .offset), offset >= 0 else {
            if let offset = try? c.decode(Int.self, forKey: .offset), offset < 0 { throw RemoteProtocolError.negativeOffset }
            throw RemoteProtocolError.invalidField("offset")
        }
        guard c.contains(.totalBytes), let totalBytes = try? c.decode(Int.self, forKey: .totalBytes), totalBytes >= 0 else { throw RemoteProtocolError.invalidField("total_bytes") }
        guard c.contains(.revision), let revision = try? c.decode(String.self, forKey: .revision), !revision.isEmpty else { throw RemoteProtocolError.missingField("revision") }
        guard c.contains(.dataBase64), let dataBase64 = try? c.decode(String.self, forKey: .dataBase64) else { throw RemoteProtocolError.missingField("data_base64") }
        guard c.contains(.eof), let eof = try? c.decode(Bool.self, forKey: .eof) else { throw RemoteProtocolError.missingField("eof") }
        self.init(artifactId: artifactId, offset: offset, totalBytes: totalBytes, revision: revision, dataBase64: dataBase64, eof: eof)
        _ = try decodedBytes()
    }

    /// Decodes the response bytes after enforcing the fetch-chunk limit.
    ///
    /// - Returns: The decoded chunk bytes.
    /// - Throws: ``RemoteProtocolError`` for malformed or oversized data.
    public func decodedBytes() throws -> Data {
        guard let data = Data(base64Encoded: dataBase64), data.base64EncodedString() == dataBase64 else { throw RemoteProtocolError.invalidBase64 }
        guard data.count <= TerminalArtifactLimits.fetchChunkBytes else { throw RemoteProtocolError.chunkTooLarge(maxBytes: TerminalArtifactLimits.fetchChunkBytes) }
        return data
    }

    private enum CodingKeys: String, CodingKey {
        case artifactId, offset, totalBytes, revision, dataBase64, eof
    }
}

/// Parameters for `terminal.artifact.thumbnail`.
