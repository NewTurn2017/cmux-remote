import Foundation

public struct ChunkUploadCommitResult: Codable, Sendable, Equatable {
    /// Upload identifier.
    public var uploadId: String
    /// Stored normalized filename.
    public var filename: String
    /// Absolute path chosen by the relay.
    public var path: String
    /// Number of committed bytes.
    public var bytes: Int
    /// Stored MIME type.
    public var mimeType: String
    /// Verified lowercase hexadecimal SHA-256 digest.
    public var sha256: String

    /// Creates committed upload metadata.
    public init(uploadId: String, filename: String, path: String, bytes: Int, mimeType: String, sha256: String) {
        self.uploadId = uploadId; self.filename = filename; self.path = path
        self.bytes = bytes; self.mimeType = mimeType; self.sha256 = sha256
    }
    private enum CodingKeys: String, CodingKey {
        case uploadId, filename, path, bytes, mimeType, sha256
    }
}

/// Parameters for `file.upload.cancel`.
