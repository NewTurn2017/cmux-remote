import Foundation
import OSLog

public actor WSClient {
    public let url: URL
    public let headers: [String: String]

    public var onText: (@Sendable (String) -> Void)?
    public var onOpen: (@Sendable () async -> Void)?
    public var onClose: (@Sendable (Int) -> Void)?

    private var task: (any WSClientConnection)?
    private let connectionFactory: any WSClientConnectionFactory
    private let reconnectDelay: @Sendable (TimeInterval) async throws -> Void
    private let beforeReconnect: @Sendable () async throws -> Void
    private var generation: UInt64 = 0
    private var openGeneration: UInt64?
    private var flushingGeneration: UInt64?
    private var closeNotificationGeneration: UInt64?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pendingTexts: [String] = []
    private var backoff: TimeInterval = 1.0
    private var shouldReconnect = true
    private let log = Logger(subsystem: "com.genie.cmuxremote", category: "ws")

    public init(
        url: URL,
        headers: [String: String],
        beforeReconnect: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.url = url
        self.headers = headers
        connectionFactory = URLSessionWebSocketConnectionFactory()
        reconnectDelay = { delay in
            // Reconnect backoff is an intended bounded delay; injection keeps tests event-driven.
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        self.beforeReconnect = beforeReconnect
    }

    init(
        url: URL,
        headers: [String: String],
        connectionFactory: any WSClientConnectionFactory,
        reconnectDelay: @escaping @Sendable (TimeInterval) async throws -> Void,
        beforeReconnect: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.url = url
        self.headers = headers
        self.connectionFactory = connectionFactory
        self.reconnectDelay = reconnectDelay
        self.beforeReconnect = beforeReconnect
    }

    public func setOnText(_ handler: (@Sendable (String) -> Void)?) {
        onText = handler
    }

    public func setOnOpen(_ handler: (@Sendable () async -> Void)?) {
        onOpen = handler
    }

    public func setOnClose(_ handler: (@Sendable (Int) -> Void)?) {
        onClose = handler
    }

    public func connect() async {
        await startConnection(clearPending: generation != 0)
    }

    public func send(text: String) async {
        guard shouldReconnect else { return }
        guard let currentTask = task,
              openGeneration == generation,
              flushingGeneration != generation
        else {
            pendingTexts.append(text)
            return
        }

        let currentGeneration = generation
        do {
            try await currentTask.send(text: text)
        } catch {
            guard shouldReconnect, generation == currentGeneration, task === currentTask else { return }
            notifySendFailure(generation: currentGeneration, message: error.localizedDescription)
        }
    }

    public func close() async {
        shouldReconnect = false
        generation &+= 1
        openGeneration = nil
        flushingGeneration = nil
        closeNotificationGeneration = nil
        pendingTexts.removeAll()
        reconnectTask?.cancel()
        reconnectTask = nil
        await stopCurrentConnection()
    }

    private func startConnection(clearPending: Bool) async {
        shouldReconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        generation &+= 1
        let currentGeneration = generation
        openGeneration = nil
        flushingGeneration = nil
        closeNotificationGeneration = nil
        if clearPending {
            pendingTexts.removeAll()
        }

        await stopCurrentConnection()

        let offered = (headers["Sec-WebSocket-Protocol"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let connection = await connectionFactory.makeConnection(
            url: url,
            headers: headers,
            protocols: offered,
            onOpen: { [weak self] in
                await self?.connectionDidOpen(generation: currentGeneration)
            },
            onClose: { [weak self] code in
                await self?.connectionDidClose(generation: currentGeneration, code: code)
            }
        )
        guard shouldReconnect, generation == currentGeneration else {
            await connection.cancel()
            return
        }

        task = connection
        startReceiveLoop(connection, generation: currentGeneration)
        await connection.resume()
        guard shouldReconnect, generation == currentGeneration, task === connection else { return }
    }

    private func stopCurrentConnection() async {
        let currentTask = task
        let currentReceiveTask = receiveTask
        task = nil
        receiveTask = nil
        currentReceiveTask?.cancel()
        await currentTask?.cancel()
        await currentReceiveTask?.value
    }

    private func startReceiveLoop(
        _ currentTask: any WSClientConnection,
        generation currentGeneration: UInt64
    ) {
        receiveTask = Task { [weak self] in
            guard let self,
                  let close = await self.receiveLoop(currentTask, generation: currentGeneration)
            else { return }

            Task { [weak self] in
                await self?.connectionDidClose(
                    generation: currentGeneration,
                    code: close.code,
                    message: close.message
                )
            }
        }
    }

    private func connectionDidOpen(generation currentGeneration: UInt64) async {
        guard shouldReconnect,
              generation == currentGeneration,
              task != nil,
              openGeneration != currentGeneration
        else { return }

        openGeneration = currentGeneration
        backoff = 1.0
        await onOpen?()

        guard shouldReconnect,
              generation == currentGeneration,
              openGeneration == currentGeneration,
              task != nil
        else { return }

        flushingGeneration = currentGeneration
        await flushPendingTexts(generation: currentGeneration)
    }

    private func flushPendingTexts(generation currentGeneration: UInt64) async {
        while shouldReconnect,
              generation == currentGeneration,
              openGeneration == currentGeneration,
              let currentTask = task,
              !pendingTexts.isEmpty
        {
            let text = pendingTexts.removeFirst()
            do {
                try await currentTask.send(text: text)
            } catch {
                guard shouldReconnect, generation == currentGeneration, task === currentTask else { return }
                pendingTexts.insert(text, at: 0)
                flushingGeneration = nil
                notifySendFailure(generation: currentGeneration, message: error.localizedDescription)
                return
            }
        }
        if generation == currentGeneration {
            flushingGeneration = nil
        }
    }

    private func connectionDidClose(
        generation currentGeneration: UInt64,
        code: Int,
        message: String? = nil
    ) async {
        guard shouldReconnect,
              generation == currentGeneration,
              task != nil
        else { return }

        let shouldNotifyClose = closeNotificationGeneration != currentGeneration
        generation &+= 1
        let reconnectGeneration = generation
        openGeneration = nil
        flushingGeneration = nil
        closeNotificationGeneration = nil
        await stopCurrentConnection()

        if let message {
            log.error("websocket closed: \(message, privacy: .public)")
        }
        if shouldNotifyClose {
            onClose?(code)
        }
        scheduleReconnect(generation: reconnectGeneration)
    }

    private func receiveLoop(
        _ currentTask: any WSClientConnection,
        generation currentGeneration: UInt64
    ) async -> (code: Int, message: String)? {
        while shouldReconnect, generation == currentGeneration, task === currentTask {
            do {
                let text = try await currentTask.receiveText()
                guard shouldReconnect, generation == currentGeneration, task === currentTask else { return nil }
                if let text {
                    onText?(text)
                }
            } catch {
                return (await currentTask.closeCode(), error.localizedDescription)
            }
        }
        return nil
    }

    private func notifySendFailure(generation currentGeneration: UInt64, message: String) {
        log.error("websocket send failed: \(message, privacy: .public)")
        guard closeNotificationGeneration != currentGeneration else { return }
        closeNotificationGeneration = currentGeneration
        onClose?(-1)
    }

    private func scheduleReconnect(generation reconnectGeneration: UInt64) {
        let delay = min(backoff, 30)
        let reconnectDelay = reconnectDelay
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do {
                try await reconnectDelay(delay)
            } catch {
                return
            }
            await self?.performReconnect(generation: reconnectGeneration, completedDelay: delay)
        }
    }

    private func performReconnect(generation reconnectGeneration: UInt64, completedDelay: TimeInterval) async {
        guard shouldReconnect, generation == reconnectGeneration else { return }
        reconnectTask = nil
        do {
            try await beforeReconnect()
        } catch {
            guard shouldReconnect, generation == reconnectGeneration else { return }
            log.error("websocket reconnect preflight failed: \(error.localizedDescription, privacy: .public)")
            if Self.isRetryablePreflightError(error) {
                backoff = min(Self.retryDelay(for: error) ?? completedDelay * 2, 30)
                scheduleReconnect(generation: reconnectGeneration)
            } else {
                shouldReconnect = false
                onClose?(Self.preflightFailureCode(for: error))
            }
            return
        }
        guard shouldReconnect, generation == reconnectGeneration else { return }
        backoff = min(completedDelay * 2, 30)
        await startConnection(clearPending: false)
    }

    private static func isRetryablePreflightError(_ error: Error) -> Bool {
        RelayCredentialRetrier.isRetryable(error)
    }

    private static func retryDelay(for error: Error) -> TimeInterval? {
        guard case let AuthError.relayUnavailable(_, retryAfter) = error else {
            return nil
        }
        return retryAfter
    }

    private static func preflightFailureCode(for error: Error) -> Int {
        if case AuthError.pairingRemoved = error { return 4401 }
        return -2
    }
}
