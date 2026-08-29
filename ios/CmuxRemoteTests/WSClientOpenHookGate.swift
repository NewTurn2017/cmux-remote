actor WSClientOpenHookGate {
    private let startStream: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init() {
        (startStream, startContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func starts() -> AsyncStream<Void> {
        startStream
    }

    func wait() async {
        startContinuation.yield()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
