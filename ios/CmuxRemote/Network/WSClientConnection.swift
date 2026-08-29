import Foundation

protocol WSClientConnection: AnyObject, Sendable {
    func resume() async
    func send(text: String) async throws
    func receiveText() async throws -> String?
    func closeCode() async -> Int
    func cancel() async
}
