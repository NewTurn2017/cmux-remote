import Foundation

protocol AttachmentSecurityScope: Sendable {
    func startAccessingSecurityScopedResource(for url: URL) async -> Bool
    func stopAccessingSecurityScopedResource(for url: URL) async
}
