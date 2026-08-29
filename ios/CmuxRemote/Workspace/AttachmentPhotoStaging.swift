import Foundation

/// Stages picker-provided photo bytes as an attachment selection.
protocol AttachmentPhotoStaging: Sendable {
    func stage(_ data: Data) async throws -> AttachmentSelection
    func remove(_ selection: AttachmentSelection) async
}

enum AttachmentPhotoStagingError: Error, Equatable {
    case invalidImage
    case encodingFailed
}
