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
    public let socketPath: String
    public let group: EventLoopGroup
    public var onReset: (() -> Void)?

    private let logger = Logger(label: "CmuxConnection")
    private var lastBootId: String?
    private var client: CMUXClient?

    public init(socketPath: String = cmuxSocketPath(),
                group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1))
    {
        self.socketPath = socketPath
        self.group = group
    }

    /// Test factory — points at a non-existent socket so calling `connect()`
    /// would fail, but `observe()` (which is the unit under test for boot_id
    /// behavior) is callable in isolation without needing a real cmux.
    public static func makeForTesting() -> CmuxConnection {
        CmuxConnection(socketPath: "/tmp/.no-such-cmux-socket",
                       group: MultiThreadedEventLoopGroup(numberOfThreads: 1))
    }

    public func connect() async throws -> CMUXClient {
        if let c = client { return c }
        let chan = try await UnixSocketChannel(path: socketPath, group: group)
            .connect { _ in self.group.next().makeSucceededFuture(()) }
        let c = CMUXClient(channel: chan, requestTimeout: .seconds(5))
        self.client = c
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
