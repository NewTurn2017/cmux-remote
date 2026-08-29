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
    enum ReadinessError: Error, Equatable {
        case timeout
    }

    let group: MultiThreadedEventLoopGroup
    let serverChannel: Channel
    let clientChannel: Channel
    let acceptedChannel: Channel
    let client: CMUXClient
    let serverInbox: ServerInbox
    let socketDirectory: URL?
    let shutdownCoordinator: FixtureShutdownCoordinator

    private init(
        group: MultiThreadedEventLoopGroup,
        serverChannel: Channel,
        clientChannel: Channel,
        acceptedChannel: Channel,
        client: CMUXClient,
        serverInbox: ServerInbox,
        socketDirectory: URL? = nil,
        shutdownGate: FixtureOperationGate? = nil,
        shutdownCompletionWaiterRegistered: (@Sendable () -> Void)? = nil
    ) {
        self.group = group
        self.serverChannel = serverChannel
        self.clientChannel = clientChannel
        self.acceptedChannel = acceptedChannel
        self.client = client
        self.serverInbox = serverInbox
        self.socketDirectory = socketDirectory
        self.shutdownCoordinator = FixtureShutdownCoordinator(
            channels: [acceptedChannel, clientChannel, serverChannel],
            group: group,
            gate: shutdownGate,
            finalizer: socketDirectory.map { directory in
                { @Sendable in
                    try FileManager.default.removeItem(at: directory)
                }
            },
            completionWaiterRegistered: shutdownCompletionWaiterRegistered
        )
    }

    static func make(
        requestTimeout: TimeAmount = .seconds(2),
        setupTimeout: Duration = .seconds(2),
        deadlineScheduler: FixtureDeadlineScheduling = DispatchFixtureDeadlineScheduler.shared,
        closeClientBeforeInboundInstallation: Bool = false,
        awaitReadiness: Bool = true,
        inboundInstallationGate: CMUXClient.InboundInstallationGate? = nil
    ) async throws -> MTELGCmuxFixture {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let inbox = ServerInbox()
        var setupChannels: [Channel] = []

        do {
            let serverFuture = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 4)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandlers([
                        LineFrameDecoder(),
                        LineFrameEncoder(),
                        ServerInboundHandler(inbox: inbox),
                    ])
                }
                .bind(host: "127.0.0.1", port: 0)
            let serverChannel = try await Self.awaitSetupChannel(
                serverFuture,
                timeout: setupTimeout,
                scheduler: deadlineScheduler
            )
            setupChannels.append(serverChannel)
            guard let port = serverChannel.localAddress?.port else {
                throw FixtureError.missingServerPort
            }

            let clientFuture = ClientBootstrap(group: group)
                .connectTimeout(setupTimeout.nioTimeAmount)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.pipeline.addHandlers([
                        LineFrameDecoder(),
                        LineFrameEncoder(),
                    ])
                }
                .connect(host: "127.0.0.1", port: port)
            let clientChannel = try await Self.awaitSetupChannel(
                clientFuture,
                timeout: setupTimeout,
                scheduler: deadlineScheduler
            )
            setupChannels.append(clientChannel)

            let acceptedChannel = try await Self.awaitAcceptedChannel(
                from: inbox,
                timeout: setupTimeout
            )
            setupChannels.append(acceptedChannel)
            if closeClientBeforeInboundInstallation {
                try await clientChannel.close().get()
            }
            let client: CMUXClient
            if let inboundInstallationGate {
                client = CMUXClient(
                    channel: clientChannel,
                    requestTimeout: requestTimeout,
                    inboundInstallationGate: inboundInstallationGate
                )
            } else {
                client = CMUXClient(channel: clientChannel, requestTimeout: requestTimeout)
            }
            let fixture = MTELGCmuxFixture(
                group: group,
                serverChannel: serverChannel,
                clientChannel: clientChannel,
                acceptedChannel: acceptedChannel,
                client: client,
                serverInbox: inbox
            )
            if awaitReadiness {
                try await Self.awaitReadiness(timeout: setupTimeout) {
                    try await client.awaitReadyOrThrow()
                }
            }
            return fixture
        } catch {
            let cleanup = FixtureShutdownCoordinator(
                channels: setupChannels,
                group: group
            )
            try? await cleanup.waitForCompletion()
            throw error
        }
    }

    static func makeUnixSocket(
        requestTimeout: TimeAmount = .seconds(2),
        setupTimeout: Duration = .seconds(2),
        deadlineScheduler: FixtureDeadlineScheduling = DispatchFixtureDeadlineScheduler.shared,
        socketDirectory requestedSocketDirectory: URL? = nil,
        shutdownGate: FixtureOperationGate? = nil,
        shutdownCompletionWaiterRegistered: (@Sendable () -> Void)? = nil
    ) async throws -> MTELGCmuxFixture {
        let socketDirectory = requestedSocketDirectory ?? URL(
            fileURLWithPath: "/tmp/cmux-uds-\(UUID().uuidString.prefix(12))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: socketDirectory,
            withIntermediateDirectories: false
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let inbox = ServerInbox()
        let socketPath = socketDirectory.appendingPathComponent("control.sock").path
        var setupChannels: [Channel] = []

        do {
            let serverFuture = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 4)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandlers([
                        LineFrameDecoder(),
                        LineFrameEncoder(),
                        ServerInboundHandler(inbox: inbox),
                    ])
                }
                .bind(unixDomainSocketPath: socketPath)
            let serverChannel = try await Self.awaitSetupChannel(
                serverFuture,
                timeout: setupTimeout,
                scheduler: deadlineScheduler
            )
            setupChannels.append(serverChannel)
            let connectedChannel = try await UnixSocketChannel(
                path: socketPath,
                group: group,
                connectTimeout: setupTimeout.nioTimeAmount
            ).connect { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }
            let clientChannel = try await Self.awaitSetupChannel(
                connectedChannel.eventLoop.makeSucceededFuture(connectedChannel),
                timeout: setupTimeout,
                scheduler: deadlineScheduler
            )
            setupChannels.append(clientChannel)
            let acceptedChannel = try await Self.awaitAcceptedChannel(
                from: inbox,
                timeout: setupTimeout
            )
            setupChannels.append(acceptedChannel)
            let client = CMUXClient(channel: clientChannel, requestTimeout: requestTimeout)
            let fixture = MTELGCmuxFixture(
                group: group,
                serverChannel: serverChannel,
                clientChannel: clientChannel,
                acceptedChannel: acceptedChannel,
                client: client,
                serverInbox: inbox,
                socketDirectory: socketDirectory,
                shutdownGate: shutdownGate,
                shutdownCompletionWaiterRegistered: shutdownCompletionWaiterRegistered
            )
            try await Self.awaitReadiness(timeout: setupTimeout) {
                try await client.awaitReadyOrThrow()
            }
            return fixture
        } catch {
            let cleanup = FixtureShutdownCoordinator(
                channels: setupChannels,
                group: group,
                finalizer: {
                    try FileManager.default.removeItem(at: socketDirectory)
                }
            )
            try? await cleanup.waitForCompletion()
            throw error
        }
    }

    /// Awaits exact client readiness with a bounded fail-safe deadline.
    static func awaitReadiness(
        timeout: Duration = .seconds(2),
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                // A bounded fail-safe for a missing readiness event, never a settling delay.
                try await ContinuousClock().sleep(for: timeout)
                try Task.checkCancellation()
                throw ReadinessError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private static func awaitSetupChannel(
        _ future: EventLoopFuture<Channel>,
        timeout: Duration,
        scheduler: FixtureDeadlineScheduling
    ) async throws -> Channel {
        try await FixtureSetupFutureJoin.wait(
            for: future,
            timeout: timeout,
            scheduler: scheduler
        )
    }

    private static func awaitAcceptedChannel(
        from inbox: ServerInbox,
        timeout: Duration
    ) async throws -> Channel {
        try await withThrowingTaskGroup(of: Channel.self) { group in
            group.addTask { try await inbox.nextAcceptedChannel() }
            group.addTask {
                try await ContinuousClock().sleep(for: timeout)
                try Task.checkCancellation()
                throw FixtureError.acceptedChannelTimeout
            }
            defer { group.cancelAll() }
            guard let channel = try await group.next() else {
                throw FixtureError.acceptedChannelTimeout
            }
            return channel
        }
    }

    /// Wait for the next outbound line from the client to arrive on the
    /// server side. The timeout is the behavior under test, not a settling delay.
    func awaitRequestLine(timeout nanos: UInt64 = 2_000_000_000) async throws -> String {
        let timeout = Duration.nanoseconds(Int64(clamping: nanos))
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.serverInbox.next() }
            group.addTask {
                try await ContinuousClock().sleep(for: timeout)
                try Task.checkCancellation()
                throw FixtureError.requestTimeout
            }
            defer { group.cancelAll() }
            guard let line = try await group.next() else {
                throw FixtureError.requestTimeout
            }
            return line
        }
    }

    func sendToClient(line: String) async throws {
        var buf = acceptedChannel.allocator.buffer(capacity: line.utf8.count + 1)
        buf.writeString(line)
        try await acceptedChannel.writeAndFlush(buf).get()
    }

    var cleanupState: FixtureShutdownCoordinator.State {
        shutdownCoordinator.state
    }

    func shutdown() async {
        try? await finishShutdown()
    }

    func shutdown(
        timeout: Duration,
        scheduler: FixtureDeadlineScheduling = DispatchFixtureDeadlineScheduler.shared
    ) async throws {
        do {
            try await shutdownCoordinator.wait(timeout: timeout, scheduler: scheduler)
        } catch FixtureError.shutdownTimeout {
            throw FixtureError.shutdownTimeout
        } catch {
            throw FixtureError.shutdownFailed(String(describing: error))
        }
    }

    func finishShutdown() async throws {
        do {
            try await shutdownCoordinator.waitForCompletion()
        } catch {
            throw FixtureError.shutdownFailed(String(describing: error))
        }
    }

    enum FixtureError: Error, Equatable {
        case requestTimeout
        case acceptedChannelTimeout
        case setupTimeout
        case shutdownTimeout
        case shutdownFailed(String)
        case cleanupIncomplete
        case missingServerPort
    }
}

protocol FixtureDeadlineScheduling: Sendable {
    func schedule(
        after timeout: Duration,
        action: @escaping @Sendable () -> Void
    ) -> FixtureDeadlineHandle
}

final class FixtureDeadlineHandle: @unchecked Sendable {
    private enum State { case pending, cancelled, fired }
    private let lock = NSLock()
    private var state = State.pending
    private var cancelAction: (@Sendable () -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .cancelled
    }

    func installCancelAction(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if state == .pending {
            cancelAction = action
            lock.unlock()
        } else {
            let shouldCancel = state == .cancelled
            lock.unlock()
            if shouldCancel { action() }
        }
    }

    func cancel() {
        let action: (@Sendable () -> Void)?
        lock.lock()
        if state == .pending {
            state = .cancelled
            action = cancelAction
            cancelAction = nil
        } else {
            action = nil
        }
        lock.unlock()
        action?()
    }

    func fire(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        guard state == .pending else {
            lock.unlock()
            return
        }
        state = .fired
        cancelAction = nil
        lock.unlock()
        action()
    }
}

final class DispatchFixtureDeadlineScheduler: FixtureDeadlineScheduling, @unchecked Sendable {
    static let shared = DispatchFixtureDeadlineScheduler()
    private let queue = DispatchQueue(
        label: "cmux.fixture.deadlines",
        qos: .userInitiated
    )

    func schedule(
        after timeout: Duration,
        action: @escaping @Sendable () -> Void
    ) -> FixtureDeadlineHandle {
        let handle = FixtureDeadlineHandle()
        let workItem = DispatchWorkItem {
            handle.fire(action)
        }
        handle.installCancelAction {
            workItem.cancel()
        }
        queue.asyncAfter(
            deadline: .now() + timeout.dispatchInterval,
            execute: workItem
        )
        return handle
    }
}

final class FixtureOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (@Sendable () -> Void)?

    var isHoldingOperation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return operation != nil
    }

    func hold(_ operation: @escaping @Sendable () -> Void) {
        lock.lock()
        self.operation = operation
        lock.unlock()
    }

    func release() {
        lock.lock()
        let operation = self.operation
        self.operation = nil
        lock.unlock()
        operation?()
    }
}

final class FixtureShutdownCoordinator: @unchecked Sendable {
    enum State: Equatable {
        case idle
        case running
        case timedOut
        case completed
        case failed
    }

    private final class TimedWaiter {
        let continuation: CheckedContinuation<Void, Error>
        var deadline: FixtureDeadlineHandle?

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private let startOperation: @Sendable (@escaping @Sendable (Result<Void, Error>) -> Void) -> Void
    private let completionWaiterRegistered: (@Sendable () -> Void)?
    private var storedState = State.idle
    private var result: Result<Void, Error>?
    private var timedWaiters: [UUID: TimedWaiter] = [:]
    private var completionWaiters: [CheckedContinuation<Void, Error>] = []

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return storedState
    }

    init(
        channels: [Channel],
        group: MultiThreadedEventLoopGroup,
        gate: FixtureOperationGate? = nil,
        finalizer: (@Sendable () throws -> Void)? = nil,
        completionWaiterRegistered: (@Sendable () -> Void)? = nil
    ) {
        self.completionWaiterRegistered = completionWaiterRegistered
        startOperation = { completion in
            let operation: @Sendable () -> Void = {
                let finishGroupShutdown: @Sendable () -> Void = {
                    group.shutdownGracefully(queue: .global()) { error in
                        if let error {
                            completion(.failure(error))
                            return
                        }
                        do {
                            try finalizer?()
                            completion(.success(()))
                        } catch {
                            completion(.failure(error))
                        }
                    }
                }
                guard let eventLoop = channels.first?.eventLoop else {
                    finishGroupShutdown()
                    return
                }
                EventLoopFuture.andAllComplete(
                    channels.map { $0.close() },
                    on: eventLoop
                ).whenComplete { _ in
                    finishGroupShutdown()
                }
            }
            if let gate {
                gate.hold(operation)
            } else {
                operation()
            }
        }
    }

    func wait(
        timeout: Duration,
        scheduler: FixtureDeadlineScheduling
    ) async throws {
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            let waiter = TimedWaiter(continuation)
            let shouldStart: Bool
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            timedWaiters[id] = waiter
            shouldStart = storedState == .idle
            if shouldStart { storedState = .running }
            lock.unlock()

            if shouldStart {
                startOperation { [weak self] result in
                    self?.operationCompleted(result)
                }
            }
            let deadline = scheduler.schedule(after: timeout) { [weak self] in
                self?.timeoutWaiter(id: id)
            }
            lock.lock()
            if timedWaiters[id] === waiter {
                waiter.deadline = deadline
                lock.unlock()
            } else {
                lock.unlock()
                deadline.cancel()
            }
        }
    }

    func waitForCompletion() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let shouldStart: Bool
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            completionWaiters.append(continuation)
            shouldStart = storedState == .idle
            if shouldStart { storedState = .running }
            lock.unlock()
            completionWaiterRegistered?()
            if shouldStart {
                startOperation { [weak self] result in
                    self?.operationCompleted(result)
                }
            }
        }
    }

    private func timeoutWaiter(id: UUID) {
        let waiter: TimedWaiter?
        lock.lock()
        waiter = timedWaiters.removeValue(forKey: id)
        if waiter != nil, result == nil { storedState = .timedOut }
        lock.unlock()
        waiter?.continuation.resume(
            throwing: MTELGCmuxFixture.FixtureError.shutdownTimeout
        )
    }

    private func operationCompleted(_ result: Result<Void, Error>) {
        let timed: [TimedWaiter]
        let completion: [CheckedContinuation<Void, Error>]
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        storedState = result.isSuccess ? .completed : .failed
        timed = Array(timedWaiters.values)
        timedWaiters.removeAll()
        completion = completionWaiters
        completionWaiters.removeAll()
        lock.unlock()

        for waiter in timed {
            waiter.deadline?.cancel()
            waiter.continuation.resume(with: result)
        }
        for waiter in completion {
            waiter.resume(with: result)
        }
    }
}

final class FixtureSetupFutureJoin: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: CheckedContinuation<Channel, Error>
    private var deadline: FixtureDeadlineHandle?
    private var timedOut = false
    private var completed = false

    private init(_ continuation: CheckedContinuation<Channel, Error>) {
        self.continuation = continuation
    }

    static func wait(
        for future: EventLoopFuture<Channel>,
        timeout: Duration,
        scheduler: FixtureDeadlineScheduling
    ) async throws -> Channel {
        try await withCheckedThrowingContinuation { continuation in
            let join = FixtureSetupFutureJoin(continuation)
            let deadline = scheduler.schedule(after: timeout) {
                join.markTimedOut()
            }
            join.install(deadline: deadline)
            future.whenComplete { result in
                join.complete(with: result)
            }
        }
    }

    private func install(deadline: FixtureDeadlineHandle) {
        lock.lock()
        if completed {
            lock.unlock()
            deadline.cancel()
        } else {
            self.deadline = deadline
            lock.unlock()
        }
    }

    private func markTimedOut() {
        lock.lock()
        if !completed { timedOut = true }
        lock.unlock()
    }

    private func complete(with result: Result<Channel, Error>) {
        let didTimeOut: Bool
        let deadline: FixtureDeadlineHandle?
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        didTimeOut = timedOut
        deadline = self.deadline
        self.deadline = nil
        lock.unlock()
        deadline?.cancel()

        guard didTimeOut else {
            continuation.resume(with: result)
            return
        }
        switch result {
        case .success(let channel):
            channel.close().whenComplete { _ in
                self.continuation.resume(
                    throwing: MTELGCmuxFixture.FixtureError.setupTimeout
                )
            }
        case .failure:
            continuation.resume(
                throwing: MTELGCmuxFixture.FixtureError.setupTimeout
            )
        }
    }
}

private extension Result where Success == Void, Failure == Error {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

private extension Duration {
    var nioTimeAmount: TimeAmount {
        .nanoseconds(Int64(clamping: totalNanoseconds))
    }

    var dispatchInterval: DispatchTimeInterval {
        .nanoseconds(Int(clamping: totalNanoseconds))
    }

    private var totalNanoseconds: Int64 {
        let components = self.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let nanos = components.attoseconds / 1_000_000_000
        let sum = seconds.partialValue.addingReportingOverflow(nanos)
        if seconds.overflow || sum.overflow {
            return components.seconds >= 0 ? Int64.max : Int64.min
        }
        return sum.partialValue
    }
}

/// Buffered async queue whose line and accepted-channel waiters are removed
/// and resumed exactly once when their task is cancelled.
final class ServerInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = []
    private var lineWaiters: [UUID: CheckedContinuation<String, Error>] = [:]
    private var acceptedChannel: Channel?
    private var channelWaiters: [UUID: CheckedContinuation<Channel, Error>] = [:]

    var pendingLineWaiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lineWaiters.count
    }

    func install(channel: Channel) {
        let waiter: CheckedContinuation<Channel, Error>?
        lock.lock()
        if let id = channelWaiters.keys.first {
            waiter = channelWaiters.removeValue(forKey: id)
        } else {
            acceptedChannel = channel
            waiter = nil
        }
        lock.unlock()
        waiter?.resume(returning: channel)
    }

    func nextAcceptedChannel() async throws -> Channel {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let channel: Channel?
                let cancelled: Bool
                lock.lock()
                channel = acceptedChannel
                cancelled = Task.isCancelled
                if channel == nil, !cancelled {
                    channelWaiters[id] = continuation
                }
                lock.unlock()

                if let channel {
                    continuation.resume(returning: channel)
                } else if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let waiter: CheckedContinuation<Channel, Error>?
            lock.lock()
            waiter = channelWaiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.resume(throwing: CancellationError())
        }
    }

    func push(_ line: String) {
        let waiter: CheckedContinuation<String, Error>?
        lock.lock()
        if let id = lineWaiters.keys.first {
            waiter = lineWaiters.removeValue(forKey: id)
        } else {
            buffer.append(line)
            waiter = nil
        }
        lock.unlock()
        waiter?.resume(returning: line)
    }

    func next() async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let line: String?
                let cancelled: Bool
                lock.lock()
                line = buffer.isEmpty ? nil : buffer.removeFirst()
                cancelled = Task.isCancelled
                if line == nil, !cancelled {
                    lineWaiters[id] = continuation
                }
                lock.unlock()

                if let line {
                    continuation.resume(returning: line)
                } else if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let waiter: CheckedContinuation<String, Error>?
            lock.lock()
            waiter = lineWaiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.resume(throwing: CancellationError())
        }
    }
}

/// Server-side NIO handler — already sees one line per channelRead because
/// `LineFrameDecoder` is upstream. Decodes UTF-8 and forwards to the inbox.
private final class ServerInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let inbox: ServerInbox
    init(inbox: ServerInbox) { self.inbox = inbox }
    func handlerAdded(context: ChannelHandlerContext) {
        inbox.install(channel: context.channel)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = self.unwrapInboundIn(data)
        guard let str = buf.getString(at: buf.readerIndex, length: buf.readableBytes) else { return }
        inbox.push(str)
    }
}
