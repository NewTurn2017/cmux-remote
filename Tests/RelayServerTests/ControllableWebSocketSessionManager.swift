@_spi(RelayServer) import RelayCore
@testable import RelayServer

/// Suspends, succeeds, or fails WebSocket attachment while recording exact lifecycle events.
actor ControllableWebSocketSessionManager: WebSocketSessionManaging {
    private let backing: SessionManager
    private var modes: [ControllableWebSocketSessionMode]
    private var pendingAttachments: [Int: CheckedContinuation<Void, Never>] = [:]
    private var attachAttempts = 0
    private var detachAttempts = 0
    private let attachEventsStream: AsyncStream<Int>
    private let attachEventsContinuation: AsyncStream<Int>.Continuation

    init(
        backing: SessionManager,
        modes: [ControllableWebSocketSessionMode]
    ) {
        self.backing = backing
        self.modes = modes
        let events = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(16))
        self.attachEventsStream = events.stream
        self.attachEventsContinuation = events.continuation
    }

    func attachEvents() -> AsyncStream<Int> {
        attachEventsStream
    }

    func attachForBoundedOutputEvents(
        deviceId: String,
        sendOutputEvent: @escaping @Sendable (SessionOutboundEvent) -> Void
    ) async throws -> Session {
        attachAttempts += 1
        let attempt = attachAttempts
        attachEventsContinuation.yield(attempt)
        let mode = modes.isEmpty ? .immediate : modes.removeFirst()
        switch mode {
        case .immediate:
            break
        case .suspended:
            await withCheckedContinuation { continuation in
                pendingAttachments[attempt] = continuation
            }
        case .failure:
            throw ControllableWebSocketSessionError.failed
        }
        return await backing.attachForBoundedOutputEvents(
            deviceId: deviceId,
            sendOutputEvent: sendOutputEvent
        )
    }

    func detach(session: Session) async {
        detachAttempts += 1
        await backing.detach(session: session)
    }

    func resumeAttach(attempt: Int) {
        pendingAttachments.removeValue(forKey: attempt)?.resume()
    }

    func detachCount() -> Int {
        detachAttempts
    }
}
