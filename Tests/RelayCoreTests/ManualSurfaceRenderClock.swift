import Foundation
@testable import RelayCore

actor ManualSurfaceRenderClock: SurfaceRenderClock {
    private var time: TimeInterval = 0
    private var waiters: [UUID: ManualSurfaceRenderClockWaiter] = [:]
    private var requestContinuation: AsyncStream<ManualSurfaceRenderSleepRequest>.Continuation?

    var now: TimeInterval { time }

    func requests() -> AsyncStream<ManualSurfaceRenderSleepRequest> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            requestContinuation = continuation
        }
    }

    func sleep(for seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let deadline = time + max(0, seconds)
                waiters[id] = ManualSurfaceRenderClockWaiter(
                    deadline: deadline,
                    continuation: continuation
                )
                requestContinuation?.yield(ManualSurfaceRenderSleepRequest(
                    seconds: seconds,
                    deadline: deadline
                ))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func advanceTimeOnly(by seconds: TimeInterval) {
        time += seconds
    }

    func advance(by seconds: TimeInterval) {
        time += seconds
        let ready = waiters.filter { $0.value.deadline <= time }
        for (id, waiter) in ready {
            waiters[id] = nil
            waiter.continuation.resume()
        }
    }

    func pendingSleepCount() -> Int {
        waiters.count
    }

    private func cancel(id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}
