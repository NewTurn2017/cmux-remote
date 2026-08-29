import Foundation

protocol AttachmentPartialCreationObserver {
    func partialCreated(at url: URL) async
}
