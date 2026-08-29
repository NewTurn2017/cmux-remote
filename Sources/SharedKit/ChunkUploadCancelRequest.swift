import Foundation

public struct ChunkUploadCancelRequest: Codable, Sendable, Equatable {
    /// Upload identifier returned by begin.
    public var uploadId: String
    /// Creates a cancel request.
    public init(uploadId: String) { self.uploadId = uploadId }
    private enum CodingKeys: String, CodingKey { case uploadId }
}

/// Result for `file.upload.cancel`.
