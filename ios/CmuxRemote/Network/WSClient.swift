import Foundation
import OSLog

public actor WSClient {
    public let url: URL
    public let headers: [String: String]

    public var onText: (@Sendable (String) -> Void)?
    public var onOpen: (@Sendable () -> Void)?
    public var onClose: (@Sendable (Int) -> Void)?

    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var backoff: TimeInterval = 1.0
    private var shouldReconnect = true
    private let log = Logger(subsystem: "com.genie.cmuxremote", category: "ws")

    public init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
        let config = URLSessionConfiguration.ephemeral
        // URLSessionWebSocketTask init via `(URL, protocols:)` ignores any
        // URLRequest-level custom headers. Stash Authorization (and other
        // ancillary headers) on the session so they ride along the upgrade
        // request alongside the protocols we'll pass at connect time.
        var extra: [AnyHashable: Any] = [:]
        for (key, value) in headers where key != "Sec-WebSocket-Protocol" {
            extra[key] = value
        }
        if !extra.isEmpty { config.httpAdditionalHeaders = extra }
        self.session = URLSession(configuration: config)
    }

    public func setOnText(_ handler: (@Sendable (String) -> Void)?) {
        onText = handler
    }

    public func setOnOpen(_ handler: (@Sendable () -> Void)?) {
        onOpen = handler
    }

    public func setOnClose(_ handler: (@Sendable (Int) -> Void)?) {
        onClose = handler
    }

    public func connect() {
        shouldReconnect = true
        // URLSessionWebSocketTask validates the server's negotiated
        // subprotocol against the `protocols:` argument — setting
        // `Sec-WebSocket-Protocol` via URLRequest is silently ignored at
        // negotiate time, which made the task close the channel right
        // after the 101 handshake. Auxiliary headers (Authorization) still
        // ride on the request.
        let offered = (headers["Sec-WebSocket-Protocol"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var request = URLRequest(url: url)
        for (key, value) in headers where key != "Sec-WebSocket-Protocol" {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let task: URLSessionWebSocketTask
        if offered.isEmpty {
            task = session.webSocketTask(with: request)
        } else {
            // URLSession only accepts (URL, protocols:) — use it when we
            // have offered protocols but copy the extra headers onto a
            // request first via a custom delegate. Easiest path: pass URL
            // form and rely on the Authorization header set above before
            // we drop into the URLSession API by re-using URLRequest's URL.
            task = session.webSocketTask(with: request.url ?? url, protocols: offered)
        }
        task.resume()
        self.task = task
        onOpen?()
        backoff = 1.0
        Task { await self.receiveLoop(task) }
    }

    public func send(text: String) async {
        task?.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { await self?.notifyClose(errorCode: -1, message: error.localizedDescription) }
        }
    }

    public func close() async {
        shouldReconnect = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receiveLoop(_ currentTask: URLSessionWebSocketTask) async {
        while shouldReconnect && task === currentTask {
            do {
                let message = try await currentTask.receive()
                switch message {
                case .string(let text): onText?(text)
                case .data(let data): onText?(String(data: data, encoding: .utf8) ?? "")
                @unknown default: break
                }
            } catch {
                log.error("websocket closed: \(error.localizedDescription, privacy: .public)")
                onClose?(currentTask.closeCode.rawValue)
                if shouldReconnect { await reconnectAfterBackoff() }
                return
            }
        }
    }

    private func notifyClose(errorCode: Int, message: String) {
        log.error("websocket send failed: \(message, privacy: .public)")
        onClose?(errorCode)
    }

    private func reconnectAfterBackoff() async {
        let delay = min(backoff, 30)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        backoff = min(backoff * 2, 30)
        connect()
    }
}
