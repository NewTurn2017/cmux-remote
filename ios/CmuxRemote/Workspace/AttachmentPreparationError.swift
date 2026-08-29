import Foundation

enum AttachmentPreparationError: Error, Equatable {
    case cancelled
    case fileTooLarge
    case sourceUnavailable
    case stagingFailed
}
