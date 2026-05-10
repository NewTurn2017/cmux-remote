import Foundation
import NIOCore
import NIOPosix
@testable import CMUXClient

/// Pairs a real `CMUXClient` with a fake cmux server, both connected via
/// loopback TCP on a `MultiThreadedEventLoopGroup`. EmbeddedChannel can't
/// be used here because the CMUXClient actor schedules work via
/// `Task { await ... }` against the channel's event loop, and
/// EmbeddedEventLoop only drains queued tasks on a manual `.run()` —
/// async-let tests deadlock as a result.
///
/// One thread is enough; the server bootstrap, the client bootstrap, and
/// the actor-side hops all share it without contention in test scope.
final class MTELGCmuxFixture: @unchecked Sendable {
    let group: MultiThreadedEventLoopGroup
    let serverChannel: Channel
    let clientChannel: Channel
    let acceptedChannel: Channel
    let client: CMUXClient
    let serverInbox: ServerInbox

    private init(group: MultiThreadedEventLoopGroup,
                 serverChannel: Channel,
                 clientChannel: Channel,
                 acceptedChannel: Channel,
                 client: CMUXClient,
                 serverInbox: ServerInbox)
    {
        self.group = group
        self.serverChannel = serverChannel
        self.clientChannel = clientChannel
        self.acceptedChannel = acceptedChannel
        self.client = client
        self.serverInbox = serverInbox
    }

    static func make(requestTimeout: TimeAmount = .seconds(2)) async throws -> MTELGCmuxFixture {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let inbox = ServerInbox()
        let acceptedPromise: EventLoopPromise<Channel> = group.next().makePromise(of: Channel.self)

        let serverBootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 4)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                let added = ch.pipeline.addHandlers([
                    LineFrameDecoder(),
                    LineFrameEncoder(),
                    ServerInboundHandler(inbox: inbox),
                ])
                added.whenSuccess { _ in acceptedPromise.succeed(ch) }
                added.whenFailure { acceptedPromise.fail($0) }
                return added
            }
        let serverChannel = try await serverBootstrap.bind(host: "127.0.0.1", port: 0).get()
        let port = serverChannel.localAddress!.port!

        let clientChannel = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { ch in
                ch.pipeline.addHandlers([
                    LineFrameDecoder(),
                    LineFrameEncoder(),
                ])
            }
            .connect(host: "127.0.0.1", port: port)
            .get()

        let acceptedChannel = try await acceptedPromise.futureResult.get()
        let client = CMUXClient(channel: clientChannel, requestTimeout: requestTimeout)
        // Give the CMUXClient init's `Task { await self.installInboundHandler() }`
        // a chance to land before the test starts pumping bytes.
        try await Task.sleep(nanoseconds: 30_000_000)

        return .init(group: group,
                     serverChannel: serverChannel,
                     clientChannel: clientChannel,
                     acceptedChannel: acceptedChannel,
                     client: client,
                     serverInbox: inbox)
    }

    /// Wait for the next outbound line from the client to arrive on the
    /// server side. Times out after `nanos` nanoseconds.
    func awaitRequestLine(timeout nanos: UInt64 = 2_000_000_000) async throws -> String {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { await self.serverInbox.next() }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanos)
                return nil
            }
            let result = try await group.next()!
            group.cancelAll()
            guard let line = result else {
                throw FixtureError.timeout
            }
            return line
        }
    }

    func sendToClient(line: String) async throws {
        var buf = acceptedChannel.allocator.buffer(capacity: line.utf8.count + 1)
        buf.writeString(line)
        try await acceptedChannel.writeAndFlush(buf).get()
    }

    func shutdown() async {
        try? await acceptedChannel.close().get()
        try? await clientChannel.close().get()
        try? await serverChannel.close().get()
        try? await group.shutdownGracefully()
    }

    enum FixtureError: Error { case timeout }
}

/// Buffered async queue: producer (NIO server-side handler) calls `push`,
/// consumer (test) awaits `next()`. One waiter at a time is enough for
/// these tests.
final class ServerInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = []
    private var waiter: CheckedContinuation<String, Never>?

    func push(_ line: String) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: line)
        } else {
            buffer.append(line)
            lock.unlock()
        }
    }

    func next() async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            lock.lock()
            if !buffer.isEmpty {
                let s = buffer.removeFirst()
                lock.unlock()
                cont.resume(returning: s)
            } else {
                waiter = cont
                lock.unlock()
            }
        }
    }
}

/// Server-side NIO handler — already sees one line per channelRead because
/// `LineFrameDecoder` is upstream. Decodes UTF-8 and forwards to the inbox.
private final class ServerInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let inbox: ServerInbox
    init(inbox: ServerInbox) { self.inbox = inbox }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = self.unwrapInboundIn(data)
        guard let str = buf.getString(at: buf.readerIndex, length: buf.readableBytes) else { return }
        inbox.push(str)
    }
}
