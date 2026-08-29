import SharedKit
@testable import RelayServer

/// Suspends each cmux dispatch until released or cooperatively cancelled.
final class SuspendingInboundCMUXFacade: CMUXFacade {
    private let recorder = InboundActionExecutionRecorder()
    private let blocker: AsyncStream<Void>
    private let blockerContinuation: AsyncStream<Void>.Continuation
    private let started: AsyncStream<String>
    private let startedContinuation: AsyncStream<String>.Continuation
    private let cancelled: AsyncStream<Void>
    private let cancelledContinuation: AsyncStream<Void>.Continuation

    init() {
        let blocker = AsyncStream<Void>.makeStream()
        self.blocker = blocker.stream
        self.blockerContinuation = blocker.continuation
        let started = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(16))
        self.started = started.stream
        self.startedContinuation = started.continuation
        let cancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.cancelled = cancelled.stream
        self.cancelledContinuation = cancelled.continuation
    }

    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        await recorder.record(method)
        startedContinuation.yield(method)
        for await _ in blocker {}
        if Task.isCancelled {
            cancelledContinuation.yield()
            throw CancellationError()
        }
        return .object([:])
    }

    func startedMethods() -> AsyncStream<String> { started }
    func cancellations() -> AsyncStream<Void> { cancelled }
    func startedSnapshot() async -> [String] { await recorder.snapshot() }
    func release() { blockerContinuation.finish() }
}
