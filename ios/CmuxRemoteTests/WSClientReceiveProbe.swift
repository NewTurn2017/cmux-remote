actor WSClientReceiveProbe {
    private let activityStream: AsyncStream<Int>
    private let activityContinuation: AsyncStream<Int>.Continuation
    private var activeCount = 0
    private var maximumActiveCount = 0

    init() {
        (activityStream, activityContinuation) = AsyncStream.makeStream(of: Int.self)
    }

    func activities() -> AsyncStream<Int> {
        activityStream
    }

    func started() {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        activityContinuation.yield(activeCount)
    }

    func ended() {
        activeCount -= 1
        activityContinuation.yield(activeCount)
    }

    func observedMaximumActiveCount() -> Int {
        maximumActiveCount
    }
}
