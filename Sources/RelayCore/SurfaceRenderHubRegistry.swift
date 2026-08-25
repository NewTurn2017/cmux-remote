import Foundation
import SharedKit

/// Owns the single active ``SurfaceRenderHub`` generation permitted for each surface identifier.
public actor SurfaceRenderHubRegistry {
    /// Hard default bound for active and retiring surface generations.
    public static let defaultMaximumSurfaces = 256

    /// Number of active hubs with one or more synchronously tracked leases.
    public var activeHubCount: Int { entries.count }

    /// Number of surface generations currently draining lifecycle cleanup.
    public var cleanupTaskCount: Int { retirements.count }

    private let reader: any TerminalSourceReader
    private let configuration: SurfaceRenderHubConfiguration
    private let maximumSurfaces: Int
    private let clockFactory: @Sendable () -> any SurfaceRenderClock
    private let observer: (any SurfaceRenderHubRegistryObserving)?
    private var entries: [String: SurfaceRenderHubRegistryEntry] = [:]
    private var retirements: [String: SurfaceRenderHubRetirement] = [:]

    /// Creates a bounded per-surface render registry.
    ///
    /// - Parameters:
    ///   - reader: Shared capability-aware terminal source boundary.
    ///   - configuration: Cadence and subscriber bounds copied into each hub.
    ///   - maximumSurfaces: Maximum simultaneous active and retiring generations.
    ///   - clockFactory: Creates one independently injectable scheduler clock per surface.
    public init(
        reader: any TerminalSourceReader,
        configuration: SurfaceRenderHubConfiguration,
        maximumSurfaces: Int = SurfaceRenderHubRegistry.defaultMaximumSurfaces,
        clockFactory: @escaping @Sendable () -> any SurfaceRenderClock = {
            ContinuousSurfaceRenderClock()
        }
    ) {
        self.reader = reader
        self.configuration = configuration
        self.maximumSurfaces = max(1, maximumSurfaces)
        self.clockFactory = clockFactory
        self.observer = nil
    }

    /// Creates a registry with deterministic acquisition-boundary observation.
    init(
        reader: any TerminalSourceReader,
        configuration: SurfaceRenderHubConfiguration,
        maximumSurfaces: Int = SurfaceRenderHubRegistry.defaultMaximumSurfaces,
        clockFactory: @escaping @Sendable () -> any SurfaceRenderClock,
        observer: any SurfaceRenderHubRegistryObserving
    ) {
        self.reader = reader
        self.configuration = configuration
        self.maximumSurfaces = max(1, maximumSurfaces)
        self.clockFactory = clockFactory
        self.observer = observer
    }

    /// Acquires one callback subscription from the active generation for a surface.
    ///
    /// A lease is reserved synchronously before the registry awaits the hub actor. Acquisitions
    /// never attach to a retiring generation; they await that exact generation's cleanup and
    /// then retry against the current registry state.
    ///
    /// - Parameters:
    ///   - workspaceId: Workspace containing the surface.
    ///   - surfaceId: Surface whose actor should be shared.
    ///   - lines: Legacy plain-text line retention used by a newly created hub.
    ///   - onDiff: Existing row/cursor diff callback.
    ///   - onChecksum: Existing checksum callback.
    /// - Returns: A generation-bound lease.
    /// - Throws: ``SurfaceRenderHubError`` for workspace or collection-bound violations.
    public func subscribe(
        workspaceId: String,
        surfaceId: String,
        lines: Int,
        onDiff: @escaping @Sendable (Int, [DiffOp]) -> Void,
        onChecksum: @escaping @Sendable (String, Int) -> Void
    ) async throws -> SurfaceRenderSubscription {
        try await subscribe(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lines: lines,
            subscriber: SurfaceRenderSubscriber(
                onDiff: onDiff,
                onChecksum: onChecksum
            )
        )
    }

    /// Acquires one authoritative snapshot subscription from a surface's active generation.
    ///
    /// - Parameters:
    ///   - workspaceId: Workspace containing the surface.
    ///   - surfaceId: Surface whose actor should be shared.
    ///   - lines: Legacy plain-text line retention used by a newly created hub.
    ///   - onSnapshot: Styled authoritative snapshots accepted by the shared hub.
    ///   - onChecksum: Periodic hashes for the same authoritative snapshot stream.
    /// - Returns: A generation-bound lease.
    /// - Throws: ``SurfaceRenderHubError`` for workspace or collection-bound violations.
    public func subscribe(
        workspaceId: String,
        surfaceId: String,
        lines: Int,
        onSnapshot: @escaping @Sendable (Screen) async -> Void,
        onChecksum: @escaping @Sendable (String, Int) async -> Void
    ) async throws -> SurfaceRenderSubscription {
        try await subscribe(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lines: lines,
            subscriber: SurfaceRenderSubscriber(
                onSnapshot: onSnapshot,
                onChecksum: onChecksum
            )
        )
    }

    private func subscribe(
        workspaceId: String,
        surfaceId: String,
        lines: Int,
        subscriber: SurfaceRenderSubscriber
    ) async throws -> SurfaceRenderSubscription {
        try Task.checkCancellation()
        await observer?.acquisitionDidStart(surfaceId: surfaceId)
        try Task.checkCancellation()
        while true {
            try Task.checkCancellation()
            if let retirement = retirements[surfaceId] {
                try Task.checkCancellation()
                await retirement.task.value
                try Task.checkCancellation()
                completeRetirement(
                    surfaceId: surfaceId,
                    generation: retirement.generation
                )
                continue
            }

            var entry: SurfaceRenderHubRegistryEntry
            if let existing = entries[surfaceId] {
                guard existing.workspaceId == workspaceId else {
                    throw SurfaceRenderHubError.workspaceMismatch(
                        surfaceId: surfaceId,
                        expected: existing.workspaceId,
                        received: workspaceId
                    )
                }
                entry = existing
            } else {
                guard entries.count + retirements.count < maximumSurfaces else {
                    throw SurfaceRenderHubError.surfaceLimitReached(maximumSurfaces)
                }
                let generation = UUID()
                let hub = SurfaceRenderHub(
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    lines: lines,
                    generation: generation,
                    reader: reader,
                    configuration: configuration,
                    clock: clockFactory()
                )
                entry = SurfaceRenderHubRegistryEntry(
                    generation: generation,
                    workspaceId: workspaceId,
                    hub: hub,
                    leaseIDs: []
                )
            }

            guard entry.leaseIDs.count < configuration.maximumSubscribers else {
                throw SurfaceRenderHubError.subscriberLimitReached(
                    surfaceId: surfaceId,
                    limit: configuration.maximumSubscribers
                )
            }
            try Task.checkCancellation()
            let subscription = SurfaceRenderSubscription(
                surfaceId: surfaceId,
                generation: entry.generation
            )
            entry.leaseIDs.insert(subscription.id)
            entries[surfaceId] = entry

            var registeredWithHub = false
            do {
                await observer?.acquisitionDidReserve(subscription)
                try Task.checkCancellation()
                let registered = try await entry.hub.subscribe(
                    subscription: subscription,
                    subscriber: subscriber
                )
                registeredWithHub = true
                try Task.checkCancellation()
                await observer?.acquisitionDidRegister(registered)
                try Task.checkCancellation()
                return registered
            } catch {
                await rollbackFailedAcquisition(
                    subscription,
                    entry: entry,
                    registeredWithHub: registeredWithHub
                )
                throw error
            }
        }
    }

    /// Releases a generation-bound lease and retires the hub after its last lease.
    ///
    /// Registry lease state and retirement marking happen before any cross-actor await, so a
    /// concurrent acquisition cannot attach to a generation whose final release has started.
    ///
    /// - Parameter subscription: Lease returned by ``subscribe(workspaceId:surfaceId:lines:onDiff:onChecksum:)``.
    public func unsubscribe(_ subscription: SurfaceRenderSubscription) async {
        guard var entry = entries[subscription.surfaceId],
              entry.generation == subscription.generation,
              entry.leaseIDs.remove(subscription.id) != nil
        else {
            if let retirement = retirements[subscription.surfaceId],
               retirement.generation == subscription.generation
            {
                await retirement.task.value
                completeRetirement(
                    surfaceId: subscription.surfaceId,
                    generation: retirement.generation
                )
            }
            return
        }

        if !entry.leaseIDs.isEmpty {
            entries[subscription.surfaceId] = entry
            _ = await entry.hub.unsubscribe(subscription)
            return
        }

        entries[subscription.surfaceId] = nil
        let retirement = SurfaceRenderHubRetirement(
            generation: entry.generation,
            // The registry owns and drains this exact generation before allowing reacquisition.
            task: Task {
                _ = await entry.hub.unsubscribe(subscription)
                await entry.hub.stop()
            }
        )
        retirements[subscription.surfaceId] = retirement
        await retirement.task.value
        completeRetirement(
            surfaceId: subscription.surfaceId,
            generation: retirement.generation
        )
    }

    /// Wakes active cadence for a currently active surface after successful input.
    ///
    /// - Parameter surfaceId: Surface that accepted terminal input.
    public func noteUserInput(surfaceId: String) async {
        await entries[surfaceId]?.hub.noteUserInput()
    }

    /// Returns the authoritative styled snapshot retained by an active generation.
    ///
    /// - Parameter surfaceId: Surface to inspect.
    /// - Returns: Current screen, or `nil` before its first update and while retiring.
    public func currentSnapshot(surfaceId: String) async -> Screen? {
        await entries[surfaceId]?.hub.currentScreen
    }

    /// Returns the active generation's hub for focused RelayCore tests.
    func hub(surfaceId: String) -> SurfaceRenderHub? {
        entries[surfaceId]?.hub
    }

    /// Returns the active generation identifier for focused lifecycle tests.
    func generation(surfaceId: String) -> UUID? {
        entries[surfaceId]?.generation
    }

    private func rollbackFailedAcquisition(
        _ subscription: SurfaceRenderSubscription,
        entry reservedEntry: SurfaceRenderHubRegistryEntry,
        registeredWithHub: Bool
    ) async {
        guard var current = entries[subscription.surfaceId],
              current.generation == reservedEntry.generation
        else {
            if registeredWithHub {
                _ = await reservedEntry.hub.unsubscribe(subscription)
            }
            return
        }
        current.leaseIDs.remove(subscription.id)
        guard current.leaseIDs.isEmpty else {
            entries[subscription.surfaceId] = current
            if registeredWithHub {
                _ = await current.hub.unsubscribe(subscription)
            }
            return
        }

        entries[subscription.surfaceId] = nil
        let hub = current.hub
        let shouldUnsubscribe = registeredWithHub
        let retirement = SurfaceRenderHubRetirement(
            generation: current.generation,
            task: Task {
                if shouldUnsubscribe {
                    _ = await hub.unsubscribe(subscription)
                }
                await hub.stop()
            }
        )
        retirements[subscription.surfaceId] = retirement
        await retirement.task.value
        completeRetirement(
            surfaceId: subscription.surfaceId,
            generation: retirement.generation
        )
    }

    private func completeRetirement(surfaceId: String, generation: UUID) {
        guard retirements[surfaceId]?.generation == generation else { return }
        retirements[surfaceId] = nil
    }
}
