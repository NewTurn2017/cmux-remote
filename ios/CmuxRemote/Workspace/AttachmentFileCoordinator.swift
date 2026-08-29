import Foundation

protocol AttachmentFileCoordinator {
    func copy(from source: URL, to destination: URL, maximumBytes: Int64) async throws -> Int64
}
