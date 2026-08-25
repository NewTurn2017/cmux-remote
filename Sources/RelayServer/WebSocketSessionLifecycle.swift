import NIOCore
@_spi(RelayServer) import RelayCore

/// Confines one handler's session generation and attachment state to its NIO event loop.
///
/// `@unchecked Sendable` is sound because state access is preconditioned onto `eventLoop`;
/// the async attach path hops back to that loop before installing a session.
final class WebSocketSessionLifecycle: @unchecked Sendable {
    private let eventLoop: any EventLoop
    private let manager: any WebSocketSessionManaging
    private var generation: UInt64 = 0
    private var isActive = false
    private var session: Session?

    init(eventLoop: any EventLoop, manager: any WebSocketSessionManaging) {
        self.eventLoop = eventLoop
        self.manager = manager
    }

    /// Starts a fresh active generation on the event loop.
    func activate() -> UInt64 {
        precondition(eventLoop.inEventLoop)
        generation &+= 1
        isActive = true
        return generation
    }

    /// Invalidates pending attachment and returns the one installed session, if any.
    func invalidate() -> Session? {
        precondition(eventLoop.inEventLoop)
        generation &+= 1
        isActive = false
        defer { session = nil }
        return session
    }

    /// Returns whether a callback still belongs to the active channel generation.
    func isCurrent(_ candidateGeneration: UInt64) -> Bool {
        precondition(eventLoop.inEventLoop)
        return isActive && generation == candidateGeneration
    }

    /// Returns the installed session only for the current active generation.
    func currentSession(generation candidateGeneration: UInt64) -> Session? {
        precondition(eventLoop.inEventLoop)
        guard isCurrent(candidateGeneration) else { return nil }
        return session
    }

    /// Attaches off-loop, then atomically installs only into the requested active generation.
    func attach(
        deviceId: String,
        generation candidateGeneration: UInt64,
        sendOutputEvent: @escaping @Sendable (SessionOutboundEvent) -> Void
    ) async throws -> Bool {
        let attached = try await manager.attachForBoundedOutputEvents(
            deviceId: deviceId,
            sendOutputEvent: sendOutputEvent
        )
        let installed = await performOnEventLoop {
            guard self.isCurrent(candidateGeneration), self.session == nil else {
                return false
            }
            self.session = attached
            return true
        }
        if !installed {
            await manager.detach(session: attached)
        }
        return installed
    }

    private func performOnEventLoop<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            eventLoop.execute {
                continuation.resume(returning: operation())
            }
        }
    }
}
