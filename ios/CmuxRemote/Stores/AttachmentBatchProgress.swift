struct AttachmentBatchProgress: Equatable, Sendable {
    var sentBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var completedFiles = 0
    var totalFiles = 0
    var currentOrdinal: Int?
}
