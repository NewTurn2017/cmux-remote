import Foundation

public struct ChunkUploadBeginResult: Codable, Sendable, Equatable {
    /// Process-lifetime upload identifier.
    public var uploadId: String
    /// Stable client batch identifier accepted by the relay.
    public var batchId: String
    /// Server-enforced raw chunk size.
    public var chunkBytes: Int

    /// Creates a begin acknowledgement.
    ///
    /// - Parameters:
    ///   - uploadId: Server-generated process-lifetime upload identifier.
    ///   - batchId: Stable client batch identifier accepted by the relay.
    ///   - chunkBytes: Server-enforced raw chunk size.
    public init(uploadId: String, batchId: String, chunkBytes: Int = ChunkUploadLimits.rawChunkBytes) {
        self.uploadId = uploadId
        self.batchId = batchId
        self.chunkBytes = chunkBytes
    }
    private enum CodingKeys: String, CodingKey { case uploadId, batchId, chunkBytes }
}

/// Parameters for `file.upload.chunk`.
