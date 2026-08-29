import Foundation

public struct ChunkUploadChunkResult: Codable, Sendable, Equatable {
    /// Upload identifier.
    public var uploadId: String
    /// Offset expected for the next chunk.
    public var nextOffset: Int
    /// Number of bytes received so far.
    public var receivedBytes: Int
    /// Creates a chunk acknowledgement.
    public init(uploadId: String, nextOffset: Int, receivedBytes: Int) {
        self.uploadId = uploadId; self.nextOffset = nextOffset; self.receivedBytes = receivedBytes
    }
    private enum CodingKeys: String, CodingKey { case uploadId, nextOffset, receivedBytes }
}

/// Parameters for `file.upload.commit`.
