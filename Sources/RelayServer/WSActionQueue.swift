import NIOCore

/// Runs a bounded number of admitted asynchronous actions in strict FIFO order.
///
/// `@unchecked Sendable` is sound because mutable state is accessed only on `eventLoop`;
/// the worker task hops back to that loop before advancing the queue.
final class WSActionQueue: @unchecked Sendable {
    typealias Operation = @Sendable () async -> Void

    private let eventLoop: any EventLoop
    private let maximumOutstandingActions: Int
    private let maximumOutstandingRetainedBytes: Int
    private let backpressureThresholdBytes: Int
    private let onCapacityAvailable: @Sendable () -> Void
    private var pending: [(operation: Operation, retainedByteCount: Int)] = []
    private var worker: Task<Void, Never>?
    private var isInvalidated = false

    private(set) var outstandingActionCount = 0
    private(set) var outstandingRetainedByteCount = 0

    var shouldApplyBackpressure: Bool {
        precondition(eventLoop.inEventLoop)
        return outstandingActionCount == maximumOutstandingActions
            || outstandingRetainedByteCount >= backpressureThresholdBytes
    }

    convenience init(
        eventLoop: any EventLoop,
        maximumOutstandingActions: Int,
        onCapacityAvailable: @escaping @Sendable () -> Void
    ) {
        self.init(
            eventLoop: eventLoop,
            maximumOutstandingActions: maximumOutstandingActions,
            maximumOutstandingRetainedBytes: Int.max,
            onCapacityAvailable: onCapacityAvailable
        )
    }

    init(
        eventLoop: any EventLoop,
        maximumOutstandingActions: Int,
        maximumOutstandingRetainedBytes: Int,
        onCapacityAvailable: @escaping @Sendable () -> Void
    ) {
        self.eventLoop = eventLoop
        self.maximumOutstandingActions = max(1, maximumOutstandingActions)
        self.maximumOutstandingRetainedBytes = max(1, maximumOutstandingRetainedBytes)
        self.backpressureThresholdBytes = max(1, maximumOutstandingRetainedBytes / 2)
        self.onCapacityAvailable = onCapacityAvailable
    }

    /// Admits one action unless the queue is invalidated or already at its hard bound.
    @discardableResult
    func enqueue(_ operation: @escaping Operation) -> Bool {
        enqueue(retainedByteCount: 0, operation)
    }

    /// Admits one retained-payload action unless either hard bound is reached.
    @discardableResult
    func enqueue(
        retainedByteCount: Int,
        _ operation: @escaping Operation
    ) -> Bool {
        precondition(eventLoop.inEventLoop)
        let retainedByteCount = max(0, retainedByteCount)
        let (candidateBytes, overflow) = outstandingRetainedByteCount
            .addingReportingOverflow(retainedByteCount)
        guard !isInvalidated,
              outstandingActionCount < maximumOutstandingActions,
              !overflow,
              candidateBytes <= maximumOutstandingRetainedBytes
        else { return false }

        outstandingActionCount += 1
        outstandingRetainedByteCount = candidateBytes
        if worker == nil {
            worker = Task { [weak self] in
                await self?.drain(
                    startingWith: operation,
                    retainedByteCount: retainedByteCount
                )
            }
        } else {
            pending.append((operation, retainedByteCount))
        }
        return true
    }

    /// Cancels the active action, discards waiting actions, and permanently rejects new work.
    func invalidate() {
        precondition(eventLoop.inEventLoop)
        guard !isInvalidated else { return }
        isInvalidated = true
        pending.removeAll(keepingCapacity: false)
        outstandingActionCount = 0
        outstandingRetainedByteCount = 0
        worker?.cancel()
        worker = nil
    }

    private func drain(
        startingWith first: @escaping Operation,
        retainedByteCount firstRetainedByteCount: Int
    ) async {
        var next: (operation: Operation, retainedByteCount: Int)? = (
            first,
            firstRetainedByteCount
        )
        while let current = next {
            guard !Task.isCancelled else { return }
            await current.operation()
            guard !Task.isCancelled else { return }
            next = await completeCurrentAndTakeNext(
                retainedByteCount: current.retainedByteCount
            )
        }
    }

    private func completeCurrentAndTakeNext(
        retainedByteCount: Int
    ) async -> (operation: Operation, retainedByteCount: Int)? {
        await withCheckedContinuation { continuation in
            eventLoop.execute { [weak self] in
                guard let self, !self.isInvalidated else {
                    continuation.resume(returning: nil)
                    return
                }

                let wasApplyingBackpressure = self.shouldApplyBackpressure
                self.outstandingActionCount -= 1
                self.outstandingRetainedByteCount -= retainedByteCount
                let next: (operation: Operation, retainedByteCount: Int)?
                if self.pending.isEmpty {
                    self.worker = nil
                    next = nil
                } else {
                    next = self.pending.removeFirst()
                }
                if wasApplyingBackpressure && !self.shouldApplyBackpressure {
                    self.onCapacityAvailable()
                }
                continuation.resume(returning: next)
            }
        }
    }
}
