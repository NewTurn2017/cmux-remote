import CMUXClient
import Foundation
import SharedKit

/// Owns one capability-aware render source, scheduler, and fanout stream for a surface.
///
/// A hub performs at most one source read at a time. Calls to ``tick()`` that arrive while
/// that read is suspended collapse into one pending continuation, so slow terminal replay
/// naturally lowers effective cadence without overlapping daemon work.
public actor SurfaceRenderHub {
    /// Workspace containing the rendered surface.
    public nonisolated let workspaceId: String

    /// Surface whose terminal source this hub owns.
    public nonisolated let surfaceId: String

    /// Legacy line retention requested when render-grid replay is unavailable.
    public nonisolated let lines: Int

    /// Registry generation that owns this actor lifecycle.
    public nonisolated let generation: UUID

    /// Immutable cadence and collection bounds.
    public nonisolated let configuration: SurfaceRenderHubConfiguration

    /// Most recently accepted authoritative styled screen.
    public private(set) var currentScreen: Screen?

    /// Source API that produced ``currentScreen``.
    public private(set) var sourceMode: CMUXTerminalSourceMode?

    /// Most recently accepted render-grid producer identity.
    public private(set) var replayIdentity: CMUXTerminalReplayIdentity?

    /// Current active or idle cadence selection.
    public private(set) var cadence: SurfaceRenderCadence = .active

    /// Current target frame rate before any error backoff is applied.
    public private(set) var currentFps: Int

    /// Monotonic observability counters for this hub lifetime.
    public private(set) var metrics = SurfaceRenderHubMetrics()

    /// Most recent bounded source or release error description.
    public private(set) var lastErrorDescription: String?

    /// Number of currently registered subscribers.
    public var subscriberCount: Int { subscribers.count }

    /// Whether a source read is currently suspended.
    public var hasReadInFlight: Bool { readTask != nil }

    /// Whether one or more busy ticks have requested the coalesced continuation.
    public var hasPendingTick: Bool { pendingTick }

    /// Whether the scheduler and source lifecycle have fully stopped.
    public private(set) var isStopped = false

    private let reader: any TerminalSourceReader
    private let clock: any SurfaceRenderClock
    private var subscribers: [UUID: SurfaceRenderSubscriber] = [:]
    private var rowState = RowState()
    private var deliveryRevision = 0
    private var lastActivityAt: TimeInterval?
    private var lastChecksumAt: TimeInterval?
    private var consecutiveFailures = 0
    private var pendingTick = false
    private var inFlightReadCount = 0
    private var retiredEpochs: [String] = []
    private var schedulerTask: Task<Void, Never>?

    /// Actor-owned source task; ``stop()`` cancels and drains it before continuity release.
    private var readTask: Task<Void, Never>?
    private var readID: UUID?

    /// Creates an idle render owner; scheduling begins with the first subscriber.
    ///
    /// - Parameters:
    ///   - workspaceId: Workspace containing the surface.
    ///   - surfaceId: Stable surface identifier used by the registry.
    ///   - lines: Legacy plain-text retention requested from the daemon.
    ///   - generation: Registry lifecycle generation, or a fresh identifier by default.
    ///   - reader: Capability-aware terminal source boundary.
    ///   - configuration: Active, idle, retry, and subscriber bounds.
    ///   - clock: Injected monotonic scheduler clock.
    public init(
        workspaceId: String,
        surfaceId: String,
        lines: Int,
        generation: UUID = UUID(),
        reader: any TerminalSourceReader,
        configuration: SurfaceRenderHubConfiguration,
        clock: any SurfaceRenderClock = ContinuousSurfaceRenderClock()
    ) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.lines = max(0, lines)
        self.generation = generation
        self.reader = reader
        self.configuration = configuration
        self.clock = clock
        self.currentFps = configuration.activeFps
    }

    /// Adds one bounded diff/checksum consumer and starts scheduling when necessary.
    ///
    /// A late subscriber receives the current authoritative snapshot through the existing
    /// clear-and-row diff callback before future shared updates.
    ///
    /// - Parameters:
    ///   - onDiff: Existing relay callback for shared row and cursor operations.
    ///   - onChecksum: Existing relay callback for periodic authoritative checksums.
    /// - Returns: A lease that must be released through ``unsubscribe(_:)``.
    /// - Throws: ``SurfaceRenderHubError`` when stopped or at subscriber capacity.
    public func subscribe(
        onDiff: @escaping @Sendable (Int, [DiffOp]) -> Void,
        onChecksum: @escaping @Sendable (String, Int) -> Void
    ) async throws -> SurfaceRenderSubscription {
        guard !isStopped else {
            throw SurfaceRenderHubError.stopped(surfaceId: surfaceId)
        }
        guard subscribers.count < configuration.maximumSubscribers else {
            throw SurfaceRenderHubError.subscriberLimitReached(
                surfaceId: surfaceId,
                limit: configuration.maximumSubscribers
            )
        }

        let subscription = SurfaceRenderSubscription(
            surfaceId: surfaceId,
            generation: generation
        )
        return try subscribe(
            subscription: subscription,
            onDiff: onDiff,
            onChecksum: onChecksum
        )
    }

    /// Registers a lease already reserved by ``SurfaceRenderHubRegistry``.
    func subscribe(
        subscription: SurfaceRenderSubscription,
        onDiff: @escaping @Sendable (Int, [DiffOp]) -> Void,
        onChecksum: @escaping @Sendable (String, Int) -> Void
    ) throws -> SurfaceRenderSubscription {
        guard !isStopped else {
            throw SurfaceRenderHubError.stopped(surfaceId: surfaceId)
        }
        guard subscription.surfaceId == surfaceId,
              subscription.generation == generation
        else {
            throw SurfaceRenderHubError.stopped(surfaceId: surfaceId)
        }
        guard subscribers.count < configuration.maximumSubscribers else {
            throw SurfaceRenderHubError.subscriberLimitReached(
                surfaceId: surfaceId,
                limit: configuration.maximumSubscribers
            )
        }

        let subscriber = SurfaceRenderSubscriber(onDiff: onDiff, onChecksum: onChecksum)
        let wasEmpty = subscribers.isEmpty
        subscribers[subscription.id] = subscriber

        if let currentScreen {
            var initialState = RowState()
            let initialOperations = initialState.ingest(snapshot: currentScreen)
            subscriber.onDiff(deliveryRevision, initialOperations)
            metrics.fanoutDeliveries += 1
        }
        if wasEmpty {
            startScheduler()
        }
        return subscription
    }

    /// Removes one consumer and reports whether the registry should retire this hub.
    ///
    /// - Parameter subscription: Lease returned by ``subscribe(onDiff:onChecksum:)``.
    /// - Returns: `true` when no subscribers remain.
    public func unsubscribe(_ subscription: SurfaceRenderSubscription) -> Bool {
        subscribers.removeValue(forKey: subscription.id)
        return subscribers.isEmpty
    }

    /// Marks successful terminal input and immediately selects active cadence.
    public func noteUserInput() async {
        guard !isStopped, !subscribers.isEmpty else { return }
        let now = await clock.now
        await wakeActive(at: now)
    }

    /// Executes or coalesces one source tick.
    ///
    /// Concurrent calls share an in-flight read. Any number of busy calls request exactly
    /// one continuation after that read completes.
    public func tick() async {
        guard !isStopped, !subscribers.isEmpty else { return }
        if readTask != nil {
            _ = requestRead()
            return
        }
        let task = requestRead()
        await task?.value
    }

    /// Cancels scheduling and source work, releases continuity, and clears all retained state.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        subscribers.removeAll(keepingCapacity: false)
        pendingTick = false

        let scheduler = schedulerTask
        let read = readTask
        scheduler?.cancel()
        read?.cancel()
        _ = await read?.value
        _ = await scheduler?.value
        schedulerTask = nil
        readTask = nil
        readID = nil
        inFlightReadCount = 0

        metrics.releaseAttempts += 1
        do {
            try await reader.releaseTerminalSource(
                workspaceId: workspaceId,
                surfaceId: surfaceId
            )
        } catch {
            record(error: String(describing: error))
        }

        currentScreen = nil
        sourceMode = nil
        replayIdentity = nil
        retiredEpochs.removeAll(keepingCapacity: false)
        rowState = RowState()
    }

    private func startScheduler() {
        guard schedulerTask == nil else { return }
        // The hub owns and cancels this task when its last subscriber leaves.
        schedulerTask = Task { [weak self] in
            await self?.runScheduler()
        }
    }

    private func runScheduler() async {
        if lastActivityAt == nil {
            lastActivityAt = await clock.now
        }
        while !Task.isCancelled, !isStopped, !subscribers.isEmpty {
            let delay = await nextScheduledDelay()
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, !isStopped, !subscribers.isEmpty else { return }

            let task = requestRead()
            await task?.value
            while !Task.isCancelled, let continuation = readTask {
                await continuation.value
            }
        }
    }

    private func requestRead() -> Task<Void, Never>? {
        guard !isStopped, !subscribers.isEmpty else { return nil }
        if let readTask {
            pendingTick = true
            metrics.coalescedTicks += 1
            return readTask
        }

        let currentReadID = UUID()
        readID = currentReadID
        inFlightReadCount += 1
        metrics.readAttempts += 1
        metrics.maximumInFlightReads = max(
            metrics.maximumInFlightReads,
            inFlightReadCount
        )

        let reader = self.reader
        let workspaceId = self.workspaceId
        let surfaceId = self.surfaceId
        let lines = self.lines
        let task = Task<Void, Never> { [weak self] in
            let result: SurfaceRenderReadResult
            do {
                let outcome = try await reader.readTerminal(
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    lines: lines
                )
                result = Task.isCancelled ? .cancelled : .success(outcome)
            } catch is CancellationError {
                result = .cancelled
            } catch {
                result = .failure(String(describing: error))
            }
            guard let self else { return }
            await self.finishRead(id: currentReadID, result: result)
        }
        readTask = task
        return task
    }

    private func finishRead(id: UUID, result: SurfaceRenderReadResult) async {
        guard readID == id else { return }
        inFlightReadCount -= 1

        guard !isStopped, !subscribers.isEmpty else {
            readTask = nil
            readID = nil
            return
        }
        await handle(result)
        guard readID == id else { return }
        readTask = nil
        readID = nil

        if consecutiveFailures > 0 {
            pendingTick = false
        } else if pendingTick, !isStopped, !subscribers.isEmpty {
            pendingTick = false
            _ = requestRead()
        }
    }

    private func nextScheduledDelay() async -> TimeInterval {
        let now = await clock.now
        if let lastActivityAt, now - lastActivityAt > configuration.idleAfter {
            cadence = .idle
            currentFps = configuration.idleFps
        } else {
            cadence = .active
            currentFps = configuration.activeFps
        }

        let cadenceDelay = 1 / Double(currentFps)
        guard consecutiveFailures > 0 else { return cadenceDelay }
        let exponent = min(consecutiveFailures, 8)
        return min(
            configuration.maximumErrorBackoff,
            cadenceDelay * pow(2, Double(exponent))
        )
    }

    private func handle(_ result: SurfaceRenderReadResult) async {
        switch result {
        case .cancelled:
            return
        case .failure(let description):
            record(error: description)
        case .success(let outcome):
            switch outcome {
            case .unchanged(let identity):
                guard replayIdentity == identity else {
                    recordMalformedOutcome("unchanged replay identity does not match authoritative state")
                    return
                }
                consecutiveFailures = 0
                lastErrorDescription = nil
                metrics.unchangedOutcomes += 1

            case .ignored:
                consecutiveFailures = 0
                lastErrorDescription = nil
                metrics.ignoredOutcomes += 1

            case .updated(let update):
                guard accept(update) else { return }
                consecutiveFailures = 0
                lastErrorDescription = nil
                metrics.updatedOutcomes += 1

                var snapshot = update.screen
                let operations = rowState.ingest(snapshot: snapshot)
                if !operations.isEmpty {
                    deliveryRevision &+= 1
                    snapshot.rev = deliveryRevision
                } else if let currentScreen {
                    snapshot.rev = currentScreen.rev
                }
                currentScreen = snapshot

                let now = await clock.now
                if update.sourceMode == .renderGrid || !operations.isEmpty {
                    await wakeActive(at: now, reschedule: false)
                }

                let currentSubscribers = Array(subscribers.values)
                if !operations.isEmpty {
                    for subscriber in currentSubscribers {
                        subscriber.onDiff(deliveryRevision, operations)
                        metrics.fanoutDeliveries += 1
                    }
                }

                let checksumEligible = !operations.isEmpty || update.sourceMode == .legacyText
                if checksumEligible {
                    if let lastChecksumAt {
                        if now - lastChecksumAt >= 5 {
                            self.lastChecksumAt = now
                            let checksum = ScreenHasher.hash(snapshot)
                            for subscriber in currentSubscribers {
                                subscriber.onChecksum(checksum, deliveryRevision)
                                metrics.fanoutDeliveries += 1
                            }
                        }
                    } else {
                        lastChecksumAt = now
                    }
                }
            }
        }
    }

    private func accept(_ update: CMUXTerminalReadUpdate) -> Bool {
        switch update.sourceMode {
        case .legacyText:
            guard update.replayIdentity == nil else {
                recordMalformedOutcome("legacy source carried a replay identity")
                return false
            }
            sourceMode = .legacyText
            replayIdentity = nil
            retiredEpochs.removeAll(keepingCapacity: false)
            return true

        case .renderGrid:
            guard let candidate = update.replayIdentity else {
                recordMalformedOutcome("render-grid source omitted its replay identity")
                return false
            }

            if sourceMode == .renderGrid, let current = replayIdentity {
                if current.epoch == candidate.epoch {
                    guard candidate.revision > current.revision else {
                        metrics.ignoredOutcomes += 1
                        return false
                    }
                } else {
                    guard !retiredEpochs.contains(candidate.epoch) else {
                        metrics.ignoredOutcomes += 1
                        return false
                    }
                    retiredEpochs.removeAll { $0 == current.epoch }
                    retiredEpochs.append(current.epoch)
                    if retiredEpochs.count > 8 {
                        retiredEpochs.removeFirst(retiredEpochs.count - 8)
                    }
                }
            } else {
                retiredEpochs.removeAll(keepingCapacity: false)
            }

            sourceMode = .renderGrid
            replayIdentity = candidate
            return true
        }
    }

    private func wakeActive(
        at time: TimeInterval,
        reschedule: Bool = true
    ) async {
        let wasIdle = cadence == .idle
        lastActivityAt = time
        cadence = .active
        currentFps = configuration.activeFps

        if wasIdle, reschedule, readTask == nil {
            let previousScheduler = schedulerTask
            previousScheduler?.cancel()
            _ = await previousScheduler?.value
            schedulerTask = nil
            guard !isStopped, !subscribers.isEmpty else { return }
            startScheduler()
        }
    }

    private func recordMalformedOutcome(_ description: String) {
        metrics.ignoredOutcomes += 1
        record(error: description)
    }

    private func record(error description: String) {
        consecutiveFailures = min(consecutiveFailures + 1, 8)
        metrics.errors += 1
        lastErrorDescription = String(description.prefix(512))
    }
}
