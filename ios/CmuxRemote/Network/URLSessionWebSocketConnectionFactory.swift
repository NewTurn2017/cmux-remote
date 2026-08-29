import Foundation

struct URLSessionWebSocketConnectionFactory: WSClientConnectionFactory {
    func makeConnection(
        url: URL,
        headers: [String: String],
        protocols: [String],
        onOpen: @escaping @Sendable () async -> Void,
        onClose: @escaping @Sendable (Int) async -> Void
    ) async -> any WSClientConnection {
        let configuration = URLSessionConfiguration.ephemeral
        var additionalHeaders: [AnyHashable: Any] = [:]
        for (key, value) in headers where key != "Sec-WebSocket-Protocol" {
            additionalHeaders[key] = value
        }
        if !additionalHeaders.isEmpty {
            configuration.httpAdditionalHeaders = additionalHeaders
        }

        let delegate = URLSessionWebSocketDelegateProxy(onOpen: onOpen, onClose: onClose)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task: URLSessionWebSocketTask
        if protocols.isEmpty {
            var request = URLRequest(url: url)
            for (key, value) in headers where key != "Sec-WebSocket-Protocol" {
                request.setValue(value, forHTTPHeaderField: key)
            }
            task = session.webSocketTask(with: request)
        } else {
            task = session.webSocketTask(with: url, protocols: protocols)
        }
        return URLSessionWebSocketConnection(session: session, task: task)
    }
}
