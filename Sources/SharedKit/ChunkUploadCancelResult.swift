import Foundation

public struct ChunkUploadCancelResult: Codable, Sendable, Equatable {
    /// Upload identifier.
    public var uploadId: String
    /// Whether temporary upload state was removed.
    public var cancelled: Bool
    /// Creates a cancel result.
    public init(uploadId: String, cancelled: Bool = true) {
        self.uploadId = uploadId; self.cancelled = cancelled
    }
    private enum CodingKeys: String, CodingKey { case uploadId, cancelled }
}
