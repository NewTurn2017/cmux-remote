import Foundation

public struct ChunkUploadBeginRequest: Codable, Sendable, Equatable {
    /// Stable client-generated identifier shared by every file in one staged batch.
    public var batchId: String
    /// Original normalized filename.
    public var filename: String
    /// Deterministic MIME type selected by the client.
    public var mimeType: String
    /// Declared file size in bytes.
    public var bytes: Int
    /// Lowercase hexadecimal SHA-256 digest.
    public var sha256: String
    /// Number of files in the complete batch.
    public var batchFileCount: Int
    /// Total bytes in the complete batch.
    public var batchBytes: Int

    /// Creates a begin declaration.
    ///
    /// - Parameters:
    ///   - batchId: Stable random identifier reused for every begin and retry in this batch.
    ///   - filename: Original normalized filename.
    ///   - mimeType: Deterministic MIME type selected by the client.
    ///   - bytes: Declared file size in bytes.
    ///   - sha256: Lowercase hexadecimal SHA-256 digest.
    ///   - batchFileCount: Number of files in the complete batch.
    ///   - batchBytes: Total bytes in the complete batch.
    public init(batchId: String, filename: String, mimeType: String, bytes: Int, sha256: String,
                batchFileCount: Int, batchBytes: Int) {
        self.batchId = batchId
        self.filename = filename
        self.mimeType = mimeType
        self.bytes = bytes
        self.sha256 = sha256
        self.batchFileCount = batchFileCount
        self.batchBytes = batchBytes
    }

    private enum CodingKeys: String, CodingKey {
        case batchId, filename, mimeType, bytes, sha256, batchFileCount, batchBytes
    }

    /// Decodes and validates a begin declaration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.batchId) else { throw RemoteProtocolError.missingField("batch_id") }
        guard let batchId = try? c.decode(String.self, forKey: .batchId),
              !batchId.isEmpty,
              batchId == batchId.trimmingCharacters(in: .whitespacesAndNewlines),
              batchId.utf8.count <= 128,
              !batchId.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw RemoteProtocolError.invalidField("batch_id") }
        guard c.contains(.filename) else { throw RemoteProtocolError.missingField("filename") }
        guard let filename = try? c.decode(String.self, forKey: .filename), !filename.isEmpty else { throw RemoteProtocolError.invalidField("filename") }
        guard c.contains(.mimeType) else { throw RemoteProtocolError.missingField("mime_type") }
        guard let mimeType = try? c.decode(String.self, forKey: .mimeType), !mimeType.isEmpty else { throw RemoteProtocolError.invalidField("mime_type") }
        guard c.contains(.bytes) else { throw RemoteProtocolError.missingField("bytes") }
        guard let bytes = try? c.decode(Int.self, forKey: .bytes), bytes >= 0, bytes <= ChunkUploadLimits.maxFileBytes else { throw RemoteProtocolError.invalidField("bytes") }
        guard c.contains(.sha256), let sha256 = try? c.decode(String.self, forKey: .sha256), sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }) else { throw RemoteProtocolError.invalidField("sha256") }
        guard c.contains(.batchFileCount), let batchFileCount = try? c.decode(Int.self, forKey: .batchFileCount), (1...ChunkUploadLimits.maxBatchFiles).contains(batchFileCount) else { throw RemoteProtocolError.invalidField("batch_file_count") }
        guard c.contains(.batchBytes), let batchBytes = try? c.decode(Int.self, forKey: .batchBytes), batchBytes >= 0, batchBytes <= ChunkUploadLimits.maxBatchBytes else { throw RemoteProtocolError.invalidField("batch_bytes") }
        guard bytes <= batchBytes else { throw RemoteProtocolError.invalidField("batch_bytes") }
        self.init(batchId: batchId, filename: filename, mimeType: mimeType, bytes: bytes, sha256: sha256, batchFileCount: batchFileCount, batchBytes: batchBytes)
    }
}

/// Server acknowledgement for `file.upload.begin`.
