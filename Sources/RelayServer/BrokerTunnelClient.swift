import Foundation
import Logging
import RelayCore

public enum BrokerTunnelError: Error, Equatable, LocalizedError {
    case invalidURL
    case insecureURL
    case invalidRelayId
    case connectionTimedOut

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "broker.url must be an absolute URL without credentials or a fragment"
        case .insecureURL: return "broker.url must use https:// or wss://"
        case .invalidRelayId: return "broker.relay_id must not be empty"
        case .connectionTimedOut: return "broker WebSocket handshake or heartbeat timed out"
        }
    }
}

public actor BrokerTunnelClient {
    public typealias EnvelopeHandler = @Sendable (BrokerEnvelope) async -> Void
    public typealias DisconnectHandler = @Sendable () async -> Void

    public let url: URL
    private let relayToken: String
    private let injectedSession: URLSession?
    private let logger = Logger(label: "cmux-relay.broker")
    private var task: URLSessionWebSocketTask?
    private var activeSession: URLSession?
    private var running = false
    private var onEnvelope: EnvelopeHandler?
    private var onDisconnect: DisconnectHandler?

    public init(config: RelayConfig.Broker, session: URLSession? = nil) throws {
        self.url = try Self.webSocketURL(config: config)
        self.relayToken = config.relayToken
        self.injectedSession = session
    }

    public static func webSocketURL(config: RelayConfig.Broker) throws -> URL {
        guard !config.relayId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrokerTunnelError.invalidRelayId
        }
        guard var components = URLComponents(string: config.url),
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil
        else { throw BrokerTunnelError.invalidURL }

        let isLoopback = ["localhost", "127.0.0.1", "::1"]
            .contains(components.host?.lowercased() ?? "")
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "wss": break
        case "http" where isLoopback: components.scheme = "ws"
        case "ws" where isLoopback: break
        default: throw BrokerTunnelError.insecureURL
        }
        guard components.queryItems?.isEmpty != false else {
            throw BrokerTunnelError.invalidURL
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + "/v1/relay/ws"
        components.queryItems = [URLQueryItem(name: "relay_id", value: config.relayId)]
        guard let url = components.url else { throw BrokerTunnelError.invalidURL }
        return url
    }

    public func setOnEnvelope(_ handler: EnvelopeHandler?) {
        onEnvelope = handler
    }

    public func setOnDisconnect(_ handler: DisconnectHandler?) {
        onDisconnect = handler
    }

    public func runForever() async {
        guard !running else { return }
        running = true
        var policy = ReconnectPolicy(base: 1, cap: 30)

        while running && !Task.isCancelled {
            let connectedAt = ContinuousClock.now
            let currentSession = makeSession()
            let current = currentSession.webSocketTask(with: authorizedRequest())
            var heartbeat: Task<Void, Never>?
            activeSession = currentSession
            do {
                task = current
                current.resume()
                logger.info("connecting to broker \(self.url.absoluteString)")

                // A URLSessionWebSocketTask can otherwise remain in `.running`
                // while its proxy/TLS handshake is stalled. The first ping is
                // both a bounded readiness probe and a keepalive; later pings
                // keep intermediary idle timers from silently dropping WSS.
                heartbeat = Task {
                    do {
                        try await current.sendPing(timeout: 15)
                        while !Task.isCancelled {
                            try await Task.sleep(nanoseconds: 20_000_000_000)
                            try await current.sendPing(timeout: 15)
                        }
                    } catch {
                        if !Task.isCancelled {
                            current.cancel(with: .goingAway, reason: nil)
                        }
                    }
                }

                while running && !Task.isCancelled && task === current {
                    let message = try await current.receive()
                    let text: String
                    switch message {
                    case .string(let value): text = value
                    case .data(let value): text = String(data: value, encoding: .utf8) ?? ""
                    @unknown default: continue
                    }
                    guard let data = text.data(using: .utf8),
                          let envelope = try? JSONDecoder().decode(BrokerEnvelope.self, from: data)
                    else {
                        logger.warning("broker sent an invalid envelope")
                        continue
                    }
                    if let onEnvelope { await onEnvelope(envelope) }
                }
            } catch {
                if running && !Task.isCancelled {
                    logger.warning("broker disconnected: \(String(describing: error))")
                }
            }

            heartbeat?.cancel()
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            if injectedSession == nil {
                currentSession.invalidateAndCancel()
            }
            if activeSession === currentSession { activeSession = nil }
            if let onDisconnect { await onDisconnect() }
            if ContinuousClock.now - connectedAt > .seconds(5) { policy.reset() }
            guard running && !Task.isCancelled else { break }
            let delay = policy.nextDelay()
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        running = false
    }

    public func send(_ envelope: BrokerEnvelope) async {
        guard let task, task.state == .running,
              let data = try? JSONEncoder().encode(envelope),
              let text = String(data: data, encoding: .utf8)
        else { return }
        do {
            try await task.send(.string(text))
        } catch {
            logger.warning("broker send failed: \(String(describing: error))")
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    public func stop() {
        running = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        let currentSession = activeSession
        currentSession?.invalidateAndCancel()
        activeSession = nil
        if let injectedSession, injectedSession !== currentSession {
            injectedSession.invalidateAndCancel()
        }
    }

    private func authorizedRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(relayToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeSession() -> URLSession {
        if let injectedSession { return injectedSession }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }
}

private final class WebSocketPingCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

private extension URLSessionWebSocketTask {
    func sendPing(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let completion = WebSocketPingCompletion(continuation)
            sendPing { error in
                if let error {
                    completion.finish(.failure(error))
                } else {
                    completion.finish(.success(()))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                completion.finish(.failure(BrokerTunnelError.connectionTimedOut))
            }
        }
    }
}
