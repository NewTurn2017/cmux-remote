import Foundation

actor WSClientReconnectGate {
    private let waitStream: AsyncStream<TimeInterval>
    private let waitContinuation: AsyncStream<TimeInterval>.Continuation
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init() {
        (waitStream, waitContinuation) = AsyncStream.makeStream(of: TimeInterval.self)
    }

    func waits() -> AsyncStream<TimeInterval> {
        waitStream
    }

    func wait(delay: TimeInterval) async throws {
        waitContinuation.yield(delay)
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        try Task.checkCancellation()
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
