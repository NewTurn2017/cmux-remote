import Foundation
import SharedKit

/// Holds one WebSocket connection's leases and per-surface reconciliation baselines.
public actor Session {
    /// Device identifier authenticated for this connection.
    public let deviceId: String

    /// Compatibility callback for transports that do not perform terminal coalescing.
    public var sendFrame: (@Sendable (PushFrame) -> Void)?

    /// Number of live surface subscriptions owned by this session.
    public var activeSurfaceCount: Int { subscriptions.count }

    private let renderRegistry: SurfaceRenderHubRegistry
    private var sendOutput: (@Sendable (SessionOutboundFrame) -> Void)?
    private var sendOutputEvent: (@Sendable (SessionOutboundEvent) -> Void)?
    private var subscriptions: [String: SurfaceRenderSubscription] = [:]
    private var surfaceStates: [String: SessionSurfaceState] = [:]
    private var pendingSubscriptions: Set<String> = []
    private var cancelledPendingSubscriptions: Set<String> = []
    private var isClosed = false

    init(deviceId: String, renderRegistry: SurfaceRenderHubRegistry) {
        self.deviceId = deviceId
        self.renderRegistry = renderRegistry
    }

    /// Replaces the compatibility transport callback used for future push frames.
    ///
    /// - Parameter sendFrame: Callback to install, or `nil` to disable transport output.
    public func update(sendFrame: (@Sendable (PushFrame) -> Void)?) {
        self.sendFrame = sendFrame
        sendOutput = nil
        sendOutputEvent = nil
    }

    /// Replaces the bounded-transport callback used for future push frames.
    ///
    /// - Parameter sendOutput: Callback receiving terminal recovery metadata, or `nil`.
    public func update(sendOutput: (@Sendable (SessionOutboundFrame) -> Void)?) {
        self.sendOutput = sendOutput
        sendOutputEvent = nil
        sendFrame = nil
    }

    /// Replaces the server transport callback that also receives stream retirement events.
    ///
    /// - Parameter sendOutputEvent: Callback receiving frames and non-wire lifecycle events.
    @_spi(RelayServer)
    public func update(
        sendOutputEvent: (@Sendable (SessionOutboundEvent) -> Void)?
    ) {
        self.sendOutputEvent = sendOutputEvent
        sendOutput = nil
        sendFrame = nil
    }

    /// Pushes a nonterminal broadcast frame through the installed transport callback.
    ///
    /// - Parameter frame: Established wire frame to deliver in order.
    public func send(frame: PushFrame) {
        guard !isClosed else { return }
        emit(SessionOutboundFrame(frame: frame))
    }

    /// Acquires one shared render-hub subscription for a surface.
    ///
    /// - Parameters:
    ///   - workspaceId: Workspace containing the surface.
    ///   - surfaceId: Surface to render.
    ///   - lines: Legacy plain-text retention requested by the client.
    /// - Throws: ``SurfaceRenderHubError`` when registry bounds reject the subscription.
    public func subscribe(workspaceId: String, surfaceId: String, lines: Int) async throws {
        guard !isClosed,
              subscriptions[surfaceId] == nil,
              !pendingSubscriptions.contains(surfaceId)
        else { return }

        pendingSubscriptions.insert(surfaceId)
        surfaceStates[surfaceId] = SessionSurfaceState()
        do {
            let subscription = try await renderRegistry.subscribe(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                lines: lines,
                onSnapshot: { [weak self] snapshot in
                    await self?.receive(snapshot: snapshot, surfaceId: surfaceId)
                },
                onChecksum: { [weak self] hash, revision in
                    await self?.receiveChecksum(
                        hash: hash,
                        revision: revision,
                        surfaceId: surfaceId
                    )
                }
            )
            pendingSubscriptions.remove(surfaceId)

            if isClosed || cancelledPendingSubscriptions.remove(surfaceId) != nil {
                retireSurfaceState(surfaceId: surfaceId)
                await renderRegistry.unsubscribe(subscription)
                return
            }
            subscriptions[surfaceId] = subscription
        } catch {
            pendingSubscriptions.remove(surfaceId)
            cancelledPendingSubscriptions.remove(surfaceId)
            retireSurfaceState(surfaceId: surfaceId)
            throw error
        }
    }

    /// Sends the current authoritative styled snapshot for an explicit recovery request.
    ///
    /// Every request resets the subscriber baseline with a full frame retained by the hub.
    /// Recovery never performs another terminal source read.
    ///
    /// - Parameter surfaceId: Subscribed surface whose current snapshot is requested.
    /// - Returns: `true` when a retained authoritative snapshot was sent.
    public func sendAuthoritativeFull(surfaceId: String) async -> Bool {
        guard !isClosed,
              subscriptions[surfaceId] != nil || pendingSubscriptions.contains(surfaceId)
        else { return false }
        guard let snapshot = await renderRegistry.currentSnapshot(surfaceId: surfaceId) else {
            return false
        }
        return receive(snapshot: snapshot, surfaceId: surfaceId, forceFull: true)
    }

    /// Releases this session's lease on a surface.
    ///
    /// - Parameter surfaceId: Surface to stop receiving.
    public func unsubscribe(surfaceId: String) async {
        retireSurfaceState(surfaceId: surfaceId)
        if pendingSubscriptions.contains(surfaceId) {
            cancelledPendingSubscriptions.insert(surfaceId)
        }
        guard let subscription = subscriptions.removeValue(forKey: surfaceId) else { return }
        await renderRegistry.unsubscribe(subscription)
    }

    /// Wakes active cadence after a successful terminal input RPC.
    ///
    /// - Parameter surfaceId: Surface that accepted input.
    public func noteUserInput(surfaceId: String) async {
        guard subscriptions[surfaceId] != nil else { return }
        await renderRegistry.noteUserInput(surfaceId: surfaceId)
    }

    /// Cancels pending acquisition and releases every live hub lease.
    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        cancelledPendingSubscriptions.formUnion(pendingSubscriptions)
        let currentSubscriptions = Array(subscriptions.values)
        subscriptions.removeAll(keepingCapacity: false)
        for surfaceId in Array(surfaceStates.keys) {
            retireSurfaceState(surfaceId: surfaceId)
        }
        sendFrame = nil
        sendOutput = nil
        sendOutputEvent = nil
        for subscription in currentSubscriptions {
            await renderRegistry.unsubscribe(subscription)
        }
    }

    /// Returns the retained baseline revision for focused reconciliation tests.
    func baselineRevision(surfaceId: String) -> Int? {
        surfaceStates[surfaceId]?.baseline?.rev
    }

    @discardableResult
    private func receive(
        snapshot: Screen,
        surfaceId: String,
        forceFull: Bool = false
    ) -> Bool {
        guard !isClosed,
              subscriptions[surfaceId] != nil || pendingSubscriptions.contains(surfaceId),
              var state = surfaceStates[surfaceId]
        else { return false }

        if let baseline = state.baseline, snapshot.rev < baseline.rev {
            return false
        }
        if !forceFull, let baseline = state.baseline, snapshot.rev == baseline.rev {
            return false
        }

        let full = ScreenFull(surfaceId: surfaceId, screen: snapshot)
        let frame: PushFrame
        if forceFull || state.baseline == nil {
            frame = .screenFull(full)
        } else if let baseline = state.baseline,
                  snapshot.requiresFullReset(comparedTo: baseline)
        {
            frame = .screenFull(full)
        } else if let baseline = state.baseline {
            let operations = DiffOp.compute(from: baseline, to: snapshot)
            guard !operations.isEmpty else {
                state.baseline = snapshot
                surfaceStates[surfaceId] = state
                return false
            }
            frame = .screenDiff(ScreenDiff(
                surfaceId: surfaceId,
                rev: snapshot.rev,
                ops: operations
            ))
        } else {
            return false
        }

        state.baseline = snapshot
        surfaceStates[surfaceId] = state
        emit(SessionOutboundFrame(
            frame: frame,
            recoveryFull: full,
            streamIdentity: state.streamIdentity
        ))
        return true
    }

    private func receiveChecksum(hash: String, revision: Int, surfaceId: String) {
        guard !isClosed,
              let state = surfaceStates[surfaceId],
              let baseline = state.baseline,
              baseline.rev == revision
        else { return }

        let full = ScreenFull(surfaceId: surfaceId, screen: baseline)
        emit(SessionOutboundFrame(
            frame: .screenChecksum(ScreenChecksum(
                surfaceId: surfaceId,
                rev: revision,
                hash: hash
            )),
            recoveryFull: full,
            streamIdentity: state.streamIdentity
        ))
    }

    private func emit(_ output: SessionOutboundFrame) {
        sendOutputEvent?(.frame(output))
        sendOutput?(output)
        sendFrame?(output.frame)
    }

    private func retireSurfaceState(surfaceId: String) {
        guard let state = surfaceStates.removeValue(forKey: surfaceId) else { return }
        sendOutputEvent?(.retire(
            surfaceId: surfaceId,
            streamIdentity: state.streamIdentity
        ))
    }
}
