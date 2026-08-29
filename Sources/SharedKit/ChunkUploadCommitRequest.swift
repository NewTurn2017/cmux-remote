import Foundation

public struct ChunkUploadCommitRequest: Codable, Sendable, Equatable {
    /// Upload identifier returned by begin.
    public var uploadId: String
    /// Creates a commit request.
    public init(uploadId: String) { self.uploadId = uploadId }
    private enum CodingKeys: String, CodingKey { case uploadId }
}

/// Committed upload metadata returned by `file.upload.commit`.
