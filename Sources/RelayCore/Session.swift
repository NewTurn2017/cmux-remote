import Foundation
import SharedKit

/// Holds one WebSocket connection's leases on registry-owned surface render hubs.
public actor Session {
    /// Device identifier authenticated for this connection.
    public let deviceId: String

    /// Current transport callback installed by the WebSocket adapter.
    public var sendFrame: (@Sendable (PushFrame) -> Void)?

    /// Number of live surface subscriptions owned by this session.
    public var activeSurfaceCount: Int { subscriptions.count }

    private let renderRegistry: SurfaceRenderHubRegistry
    private var subscriptions: [String: SurfaceRenderSubscription] = [:]
    private var pendingSubscriptions: Set<String> = []
    private var cancelledPendingSubscriptions: Set<String> = []
    private var isClosed = false

    init(deviceId: String, renderRegistry: SurfaceRenderHubRegistry) {
        self.deviceId = deviceId
        self.renderRegistry = renderRegistry
    }

    /// Replaces the transport callback used for future push frames.
    ///
    /// - Parameter sendFrame: Callback to install, or `nil` to disable transport output.
    public func update(sendFrame: (@Sendable (PushFrame) -> Void)?) {
        self.sendFrame = sendFrame
    }

    /// Pushes a nonterminal broadcast frame through the installed transport callback.
    ///
    /// - Parameter frame: Established wire frame to deliver.
    public func send(frame: PushFrame) {
        guard !isClosed else { return }
        sendFrame?(frame)
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
        let send = sendFrame
        do {
            let subscription = try await renderRegistry.subscribe(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                lines: lines,
                onDiff: { revision, operations in
                    send?(.screenDiff(ScreenDiff(
                        surfaceId: surfaceId,
                        rev: revision,
                        ops: operations
                    )))
                },
                onChecksum: { hash, revision in
                    send?(.screenChecksum(ScreenChecksum(
                        surfaceId: surfaceId,
                        rev: revision,
                        hash: hash
                    )))
                }
            )
            pendingSubscriptions.remove(surfaceId)

            if isClosed || cancelledPendingSubscriptions.remove(surfaceId) != nil {
                await renderRegistry.unsubscribe(subscription)
                return
            }
            subscriptions[surfaceId] = subscription
        } catch {
            pendingSubscriptions.remove(surfaceId)
            cancelledPendingSubscriptions.remove(surfaceId)
            throw error
        }
    }

    /// Releases this session's lease on a surface.
    ///
    /// - Parameter surfaceId: Surface to stop receiving.
    public func unsubscribe(surfaceId: String) async {
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
        sendFrame = nil
        for subscription in currentSubscriptions {
            await renderRegistry.unsubscribe(subscription)
        }
    }
}
