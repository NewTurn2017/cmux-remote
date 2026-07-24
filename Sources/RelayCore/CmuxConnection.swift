import Foundation
import CMUXClient
import SharedKit
import NIOCore
import NIOPosix
import Logging

/// Owns the long-lived `CMUXClient` connection to the cmux UDS, recovers
/// from disconnects, and watches `events.stream` boot-info frames so that
/// when cmux restarts (boot_id changes) every active relay session can drop
/// stale state (subscriptions, last-rev counters, cached surfaces).
///
/// Spec section 10. M3.15 wires the `onReset` callback into
/// `SessionManager.broadcastReset()`.
public final class CmuxConnection: @unchecked Sendable {
    public var socketPath: String { socketPathResolver() }
    public let group: EventLoopGroup
    public var onReset: (() -> Void)?

    private let logger = Logger(label: "CmuxConnection")
    private let socketPathResolver: @Sendable () -> String
    private let socketPassword: String?
    private let socketCapability: String?
    private var lastBootId: String?
    private let dispatchResource: ReconnectingResource<CMUXClient>
    private let historyResource: ReconnectingResource<CMUXClient>
    private let eventsResource: ReconnectingResource<CMUXClient>

    public init(socketPath: String? = nil,
                socketPathResolver: (@Sendable () -> String)? = nil,
                group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1),
                socketPassword: String? = cmuxSocketPassword(),
                socketCapability: String? = cmuxSocketCapability())
    {
        let resolver: @Sendable () -> String
        if let socketPath {
            resolver = { socketPath }
        } else if let socketPathResolver {
            resolver = socketPathResolver
        } else {
            resolver = { cmuxSocketPath() }
        }
        self.socketPathResolver = resolver
        self.group = group
        self.socketPassword = socketPassword
        self.socketCapability = socketCapability
        let opener: @Sendable () async throws -> CMUXClient = {
            try await CmuxConnection.openClient(socketPath: resolver(),
                                                group: group,
                                                socketPassword: socketPassword,
                                                socketCapability: socketCapability)
        }
        let alive: @Sendable (CMUXClient) async -> Bool = { await $0.isUsable() }
        self.dispatchResource = ReconnectingResource(open: opener, isAlive: alive)
        // Scrollback snapshots can be several megabytes. Keep them off the
        // dispatch channel that DiffEngine polls 5–15 times per second, or a
        // history prewarm can queue real-time screen reads behind one huge
        // `surface.read_text` response.
        self.historyResource = ReconnectingResource(open: opener, isAlive: alive)
        self.eventsResource = ReconnectingResource(open: opener, isAlive: alive)
    }

    /// Test factory — points at a non-existent socket so calling `connect()`
    /// would fail, but `observe()` (which is the unit under test for boot_id
    /// behavior) is callable in isolation without needing a real cmux.
    public static func makeForTesting() -> CmuxConnection {
        CmuxConnection(socketPath: "/tmp/.no-such-cmux-socket",
                       group: MultiThreadedEventLoopGroup(numberOfThreads: 1),
                       socketPassword: nil,
                       socketCapability: nil)
    }

    /// Default entry point — returns the dispatch client used for ordinary
    /// RPC traffic (workspace.list, surface.subscribe, screen.diff, …).
    public func connect() async throws -> CMUXClient {
        try await dispatchResource.get()
    }

    /// Dedicated ordinary-RPC channel for large, low-priority scrollback
    /// snapshots. It deliberately does not share `connect()`'s channel with
    /// the real-time DiffEngine reader.
    public func connectForHistory() async throws -> CMUXClient {
        try await historyResource.get()
    }

    /// Dedicated channel for the long-lived `events.stream` subscription.
    /// cmux locks a subscribed channel into push-only mode and silently
    /// drops further RPC requests on it, so we never reuse the dispatch
    /// client for the subscription — the symptom would be every
    /// dispatched call timing out at the 5 s `CMUXClient.requestTimeout`.
    public func connectForEvents() async throws -> CMUXClient {
        try await eventsResource.get()
    }

    /// Drop the cached events client so the supervisor's next
    /// `connectForEvents()` re-dials after a detach.
    public func invalidateEvents() async {
        await eventsResource.invalidate()
    }

    private static func openClient(socketPath: String,
                                   group: EventLoopGroup,
                                   socketPassword: String?,
                                   socketCapability: String?) async throws -> CMUXClient {
        let chan = try await UnixSocketChannel(path: socketPath, group: group)
            .connect { _ in group.next().makeSucceededFuture(()) }
        let c = CMUXClient(channel: chan,
                           requestTimeout: .seconds(5),
                           socketCapability: socketCapability)
        // CMUXClient installs its inbound bridge in a fire-and-forget Task
        // inside its initializer; without this gate the very first RPC
        // races the bridge install and its response is dropped before
        // being delivered.
        await c.awaitReady()
        if let socketPassword {
            try await c.authenticate(password: socketPassword)
        }
        return c
    }

    /// Called from the events.stream handler with each `system.boot` (or
    /// equivalent) frame. The first observation seeds `lastBootId` without
    /// firing — there's no prior value to have changed.
    public func observe(bootInfo: BootInfo) {
        if let prev = lastBootId, prev != bootInfo.bootId {
            logger.info("boot_id changed", metadata: [
                "prev": .string(prev),
                "new": .string(bootInfo.bootId),
            ])
            onReset?()
        }
        lastBootId = bootInfo.bootId
    }
}
