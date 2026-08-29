import Foundation

public struct ChunkUploadLimits: Sendable, Equatable {
    /// Maximum decoded bytes in one upload chunk.
    public static let rawChunkBytes = 512 * 1024
    /// Maximum bytes in one uploaded file.
    public static let maxFileBytes = 100 * 1024 * 1024
    /// Maximum files in one upload batch.
    public static let maxBatchFiles = 10
    /// Maximum bytes in one upload batch.
    public static let maxBatchBytes = 250 * 1024 * 1024
    /// Lifetime in seconds before an abandoned upload may be removed.
    public static let abandonedUploadTTLSeconds = 60 * 60

    private init() {}
}

/// Parameters for `file.upload.begin`.
