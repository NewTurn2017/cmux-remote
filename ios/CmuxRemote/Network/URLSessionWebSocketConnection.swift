import Foundation

final class URLSessionWebSocketConnection: WSClientConnection {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(session: URLSession, task: URLSessionWebSocketTask) {
        self.session = session
        self.task = task
    }

    func resume() async {
        task.resume()
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func receiveText() async throws -> String? {
        switch try await task.receive() {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            return nil
        }
    }

    func closeCode() async -> Int {
        task.closeCode.rawValue
    }

    func cancel() async {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
