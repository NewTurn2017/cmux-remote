import Foundation

// URLSession invokes this immutable delegate across its own threads; its Sendable closures are the only stored state.
final class URLSessionWebSocketDelegateProxy: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let onOpen: @Sendable () async -> Void
    private let onClose: @Sendable (Int) async -> Void

    init(
        onOpen: @escaping @Sendable () async -> Void,
        onClose: @escaping @Sendable (Int) async -> Void
    ) {
        self.onOpen = onOpen
        self.onClose = onClose
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { await onOpen() }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { await onClose(closeCode.rawValue) }
    }
}
