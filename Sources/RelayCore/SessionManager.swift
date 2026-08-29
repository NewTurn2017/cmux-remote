import Foundation
import SharedKit

/// Owns connected sessions and the shared per-surface render-hub registry they lease.
public actor SessionManager {
    /// Number of attached WebSocket sessions.
    public var activeSessionCount: Int { sessionsById.count }

    /// Number of surface hubs currently shared by one or more sessions.
    public var activeRenderHubCount: Int {
        get async { await renderRegistry.activeHubCount }
    }

    private let renderRegistry: SurfaceRenderHubRegistry
    private var sessionsById: [ObjectIdentifier: Session] = [:]
    private var byDevice: [String: Set<ObjectIdentifier>] = [:]

    /// Creates a manager around the capability-aware production source seam.
    ///
    /// - Parameters:
    ///   - terminalReader: Shared terminal source reader used by all surface actors.
    ///   - defaultFps: Configured active target, normally 15 Hz.
    ///   - idleFps: Configured idle target, normally 5 Hz.
    ///   - clockFactory: Creates one independently injectable clock per surface.
    public init(
        terminalReader: any TerminalSourceReader,
        defaultFps: Int,
        idleFps: Int,
        clockFactory: @escaping @Sendable () -> any SurfaceRenderClock = {
            ContinuousSurfaceRenderClock()
        }
    ) {
        self.renderRegistry = SurfaceRenderHubRegistry(
            reader: terminalReader,
            configuration: SurfaceRenderHubConfiguration(
                activeFps: defaultFps,
                idleFps: idleFps
            ),
            clockFactory: clockFactory
        )
    }

    /// Creates a manager for an existing plain-text ``SurfaceReader``.
    ///
    /// - Parameters:
    ///   - reader: Legacy source adapted to capability-aware updated outcomes.
    ///   - defaultFps: Configured active target.
    ///   - idleFps: Configured idle target.
    public init(reader: any SurfaceReader, defaultFps: Int, idleFps: Int) {
        self.renderRegistry = SurfaceRenderHubRegistry(
            reader: LegacyTerminalSourceReader(reader: reader),
            configuration: SurfaceRenderHubConfiguration(
                activeFps: defaultFps,
                idleFps: idleFps
            )
        )
    }

    /// Builds, wires, and indexes one session by object identity and device identifier.
    ///
    /// - Parameters:
    ///   - deviceId: Authenticated device identifier.
    ///   - send: Transport callback for established push frames.
    /// - Returns: Attached session used by the WebSocket adapter.
    public func attach(
        deviceId: String,
        send: @escaping @Sendable (PushFrame) -> Void
    ) async -> Session {
        let session = Session(
            deviceId: deviceId,
            renderRegistry: renderRegistry,
            sendFrame: send
        )
        index(session: session)
        return session
    }

    /// Builds and indexes a session for a transport that performs bounded coalescing.
    ///
    /// - Parameters:
    ///   - deviceId: Authenticated device identifier.
    ///   - sendOutput: Callback receiving push frames with terminal recovery metadata.
    /// - Returns: Attached session used by the WebSocket adapter.
    public func attachForBoundedOutput(
        deviceId: String,
        sendOutput: @escaping @Sendable (SessionOutboundFrame) -> Void
    ) async -> Session {
        let session = Session(
            deviceId: deviceId,
            renderRegistry: renderRegistry,
            sendOutput: sendOutput
        )
        index(session: session)
        return session
    }

    /// Builds and indexes a session with relay-internal stream lifecycle output.
    ///
    /// - Parameters:
    ///   - deviceId: Authenticated device identifier.
    ///   - sendOutputEvent: Callback receiving frames and non-wire retirement events.
    /// - Returns: Attached session used by the relay server transport.
    @_spi(RelayServer)
    public func attachForBoundedOutputEvents(
        deviceId: String,
        sendOutputEvent: @escaping @Sendable (SessionOutboundEvent) -> Void
    ) async -> Session {
        let session = Session(
            deviceId: deviceId,
            renderRegistry: renderRegistry,
            sendOutputEvent: sendOutputEvent
        )
        index(session: session)
        return session
    }

    /// Removes a session from every index and releases all of its surface leases.
    ///
    /// - Parameter session: Previously attached session.
    public func detach(session: Session) async {
        let key = ObjectIdentifier(session)
        sessionsById[key] = nil
        for (deviceId, identifiers) in byDevice {
            var remaining = identifiers
            remaining.remove(key)
            byDevice[deviceId] = remaining.isEmpty ? nil : remaining
        }
        await session.close()
    }

    /// Pushes a frame to every connection authenticated as one device.
    ///
    /// - Parameters:
    ///   - deviceId: Recipient device identifier.
    ///   - frame: Established wire frame to deliver.
    public func broadcastToDevice(deviceId: String, frame: PushFrame) async {
        let identifiers = byDevice[deviceId] ?? []
        let sessions = identifiers.compactMap { sessionsById[$0] }
        for session in sessions {
            await session.send(frame: frame)
        }
    }

    /// Pushes a frame to every attached connection.
    ///
    /// - Parameter frame: Established wire frame to deliver.
    public func broadcastToAll(frame: PushFrame) async {
        for session in sessionsById.values {
            await session.send(frame: frame)
        }
    }

    /// Notifies every client that cmux restarted and local screen state is stale.
    public func broadcastReset() async {
        await broadcastToAll(frame: .event(EventFrame(
            category: .system,
            name: "cmux.reset",
            payload: .null
        )))
    }

    /// Returns a live hub's authoritative styled snapshot for reconciliation adapters.
    ///
    /// - Parameter surfaceId: Surface to inspect.
    /// - Returns: Current snapshot, or `nil` when unavailable.
    public func currentSnapshot(surfaceId: String) async -> Screen? {
        await renderRegistry.currentSnapshot(surfaceId: surfaceId)
    }

    /// Returns the registry-owned hub for focused RelayCore tests.
    func renderHub(surfaceId: String) async -> SurfaceRenderHub? {
        await renderRegistry.hub(surfaceId: surfaceId)
    }

    private func index(session: Session) {
        let key = ObjectIdentifier(session)
        sessionsById[key] = session
        byDevice[session.deviceId, default: []].insert(key)
    }
}
