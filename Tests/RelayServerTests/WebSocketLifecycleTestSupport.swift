import Foundation
import NIOCore
@_spi(RelayServer) import RelayCore
import SharedKit
@testable import RelayServer

enum WebSocketLifecycleTestError: Error {
    case timeout
}

/// Event recorder whose buffer, waiter list, and timeout cancellation are all
/// confined to one real NIO event loop. Timeouts are fail-safes, never test
/// synchronization.
final class BoundedLifecycleEventProbe<Event: Sendable>: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let promise: EventLoopPromise<Event>
        let timeout: Scheduled<Void>
    }

    private let eventLoop: any EventLoop
    private var buffered: [Event] = []
    private var waiters: [Waiter] = []

    init(eventLoop: any EventLoop) {
        self.eventLoop = eventLoop
    }

    func yield(_ event: Event) {
        eventLoop.execute {
            if self.waiters.isEmpty {
                self.buffered.append(event)
            } else {
                let waiter = self.waiters.removeFirst()
                waiter.timeout.cancel()
                waiter.promise.succeed(event)
            }
        }
    }

    func next(timeout: TimeAmount = .seconds(2)) async throws -> Event {
        let id = UUID()
        let promise = eventLoop.makePromise(of: Event.self)
        eventLoop.execute {
            if self.buffered.isEmpty {
                let scheduled = self.eventLoop.scheduleTask(in: timeout) {
                    guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                    let waiter = self.waiters.remove(at: index)
                    waiter.promise.fail(WebSocketLifecycleTestError.timeout)
                }
                self.waiters.append(.init(id: id, promise: promise, timeout: scheduled))
            } else {
                promise.succeed(self.buffered.removeFirst())
            }
        }
        return try await promise.futureResult.get()
    }
}

enum ControllableSessionMode: Sendable {
    case immediate
    case suspended
}

enum ControllableSessionEvent: Equatable, Sendable {
    case attachStarted(Int)
    case attachCancelled(Int)
    case attachReturned(Int)
    case detached(Int)
}

actor ControllableWebSocketSessionManager: WebSocketSessionManaging {
    private let backing: SessionManager
    private let events: BoundedLifecycleEventProbe<ControllableSessionEvent>
    private var modes: [ControllableSessionMode]
    private var nextAttempt = 0
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var attemptBySession: [ObjectIdentifier: Int] = [:]

    init(
        backing: SessionManager,
        modes: [ControllableSessionMode],
        events: BoundedLifecycleEventProbe<ControllableSessionEvent>
    ) {
        self.backing = backing
        self.modes = modes
        self.events = events
    }

    func attachForBoundedOutputEvents(
        deviceId: String,
        sendOutputEvent: @escaping @Sendable (SessionOutboundEvent) -> Void
    ) async throws -> Session {
        nextAttempt += 1
        let attempt = nextAttempt
        events.yield(.attachStarted(attempt))
        let mode = modes.isEmpty ? .immediate : modes.removeFirst()
        if case .suspended = mode {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    pending[attempt] = continuation
                }
            } onCancel: {
                self.events.yield(.attachCancelled(attempt))
            }
        }

        let session = await backing.attachForBoundedOutputEvents(
            deviceId: deviceId,
            sendOutputEvent: sendOutputEvent
        )
        attemptBySession[ObjectIdentifier(session)] = attempt
        events.yield(.attachReturned(attempt))
        return session
    }

    func detach(session: Session) async {
        let attempt = attemptBySession.removeValue(forKey: ObjectIdentifier(session)) ?? -1
        await backing.detach(session: session)
        events.yield(.detached(attempt))
    }

    func resumeAttach(_ attempt: Int) {
        pending.removeValue(forKey: attempt)?.resume()
    }

    func resumeAll() {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

enum SuspendingRPCEvent: Equatable, Sendable {
    case started(String)
    case cancelled(String)
    case completed(String)
}

actor SuspendingLifecycleCMUXFacade: CMUXFacade {
    private let events: BoundedLifecycleEventProbe<SuspendingRPCEvent>
    private let suspendedMethods: Set<String>
    private var pending: [String: CheckedContinuation<JSONValue, Never>] = [:]
    private var started: [String] = []

    init(
        suspendedMethods: Set<String>,
        events: BoundedLifecycleEventProbe<SuspendingRPCEvent>
    ) {
        self.suspendedMethods = suspendedMethods
        self.events = events
    }

    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        started.append(method)
        events.yield(.started(method))
        let result: JSONValue
        if suspendedMethods.contains(method) {
            result = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    pending[method] = continuation
                }
            } onCancel: {
                self.events.yield(.cancelled(method))
            }
        } else {
            result = .object(["method": .string(method)])
        }
        events.yield(.completed(method))
        return result
    }

    func release(_ method: String, result: JSONValue? = nil) {
        pending.removeValue(forKey: method)?.resume(
            returning: result ?? .object(["method": .string(method)])
        )
    }

    func releaseAll() {
        let continuations = pending
        pending.removeAll()
        for (method, continuation) in continuations {
            continuation.resume(returning: .object(["method": .string(method)]))
        }
    }

    func startedSnapshot() -> [String] {
        started
    }
}
