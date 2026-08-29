import NIOCore

/// Runs a bounded number of admitted asynchronous WebSocket actions in strict FIFO order.
///
/// Mutable state is confined to `eventLoop`. Invalidating the queue cancels and
/// severs the active task immediately; a cancellation-ignoring operation can
/// finish later, but it retains neither this queue nor its former handler.
final class WSActionQueue: @unchecked Sendable {
    typealias Operation = @Sendable () async -> Void

    private struct Entry: Sendable {
        let operation: Operation
        let retainedByteCount: Int
    }

    private let eventLoop: any EventLoop
    private let maximumOutstandingActions: Int
    private let maximumOutstandingRetainedBytes: Int
    private let backpressureThresholdBytes: Int
    private let onCapacityAvailable: @Sendable () -> Void
    private var pending: [Entry] = []
    private var activeTask: Task<Void, Never>?
    private var activeToken: UInt64?
    private var nextToken: UInt64 = 0
    private var invalidated = false

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
        guard !invalidated,
              outstandingActionCount < maximumOutstandingActions,
              !overflow,
              candidateBytes <= maximumOutstandingRetainedBytes
        else { return false }

        outstandingActionCount += 1
        outstandingRetainedByteCount = candidateBytes
        let entry = Entry(operation: operation, retainedByteCount: retainedByteCount)
        if activeTask == nil {
            start(entry)
        } else {
            pending.append(entry)
        }
        return true
    }

    func invalidate() {
        precondition(eventLoop.inEventLoop)
        guard !invalidated else { return }
        invalidated = true
        pending.removeAll(keepingCapacity: false)
        outstandingActionCount = 0
        outstandingRetainedByteCount = 0
        activeToken = nil
        let task = activeTask
        activeTask = nil
        task?.cancel()
    }

    private func start(_ entry: Entry) {
        precondition(eventLoop.inEventLoop)
        nextToken &+= 1
        let token = nextToken
        activeToken = token
        let eventLoop = self.eventLoop
        let completion: @Sendable () -> Void = { [weak self] in
            eventLoop.execute { [weak self] in
                self?.complete(token: token, retainedByteCount: entry.retainedByteCount)
            }
        }
        activeTask = Task {
            await entry.operation()
            completion()
        }
    }

    private func complete(token: UInt64, retainedByteCount: Int) {
        precondition(eventLoop.inEventLoop)
        guard !invalidated, activeToken == token else { return }
        let wasApplyingBackpressure = shouldApplyBackpressure
        outstandingActionCount -= 1
        outstandingRetainedByteCount -= retainedByteCount
        activeTask = nil
        activeToken = nil
        if !pending.isEmpty {
            start(pending.removeFirst())
        }
        if wasApplyingBackpressure && !shouldApplyBackpressure {
            onCapacityAvailable()
        }
    }
}
