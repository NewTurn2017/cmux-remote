import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOWebSocket
import SharedKit
import Testing
@testable import RelayCore
@testable import RelayServer

@Suite("WebSocket handler lifecycle", .serialized, .timeLimit(.minutes(1)))
struct WebSocketHandlerLifecycleTests {
    @Test func disconnectDuringSuspendedAttachDetachesLateSession() async throws {
        let fixture = try LifecycleFixture(sessionModes: [.suspended])
        var channel: NIOAsyncTestingChannel? = await fixture.makeChannel(cmux: fixture.facade)
        try await fixture.connect(channel)

        try await fixture.sendHello(channel)
        #expect(try await fixture.sessionEvents.next() == .attachStarted(1))
        try await channel?.close().get()
        #expect(try await fixture.sessionEvents.next() == .attachCancelled(1))

        await fixture.sessions.resumeAttach(1)
        #expect(try await fixture.sessionEvents.next() == .attachReturned(1))
        #expect(try await fixture.sessionEvents.next() == .detached(1))
        #expect(await fixture.backing.activeSessionCount == 0)

        _ = try await channel?.finish(acceptAlreadyClosed: true)
        channel = nil
        try await fixture.shutdown()
    }

    @Test func hungRPCThenInactiveDropsQueuedRPCAndReleasesHandler() async throws {
        let fixture = try LifecycleFixture(sessionModes: [.immediate], suspendedMethods: ["slow.1"])
        var handler: WebSocketHandler? = fixture.makeHandler(cmux: fixture.facade)
        weak let releasedHandler = handler
        var channel: NIOAsyncTestingChannel? = await NIOAsyncTestingChannel(handler: handler!)
        handler = nil
        try await fixture.connect(channel)

        try await fixture.sendHello(channel)
        #expect(try await fixture.sessionEvents.next() == .attachStarted(1))
        #expect(try await fixture.sessionEvents.next() == .attachReturned(1))
        try await fixture.sendRPC(channel, id: "1", method: "slow.1")
        #expect(try await fixture.rpcEvents.next() == .started("slow.1"))
        try await fixture.sendRPC(channel, id: "2", method: "slow.2")
        try await fixture.eventLoopBarrier(channel)
        #expect(await fixture.facade.startedSnapshot() == ["slow.1"])

        try await channel?.close().get()
        #expect(try await fixture.rpcEvents.next() == .cancelled("slow.1"))
        #expect(try await fixture.sessionEvents.next() == .detached(1))
        _ = try await channel?.finish(acceptAlreadyClosed: true)
        channel = nil
        #expect(releasedHandler == nil)
        #expect(await fixture.backing.activeSessionCount == 0)

        await fixture.facade.release("slow.1")
        #expect(try await fixture.rpcEvents.next() == .completed("slow.1"))
        try await fixture.shutdown()
    }

    @Test func reconnectProceedsBeforeOldAttachCompletes() async throws {
        let fixture = try LifecycleFixture(sessionModes: [.suspended, .immediate])
        var first: NIOAsyncTestingChannel? = await fixture.makeChannel(cmux: fixture.facade)
        try await fixture.connect(first)
        try await fixture.sendHello(first)
        #expect(try await fixture.sessionEvents.next() == .attachStarted(1))
        try await first?.close().get()
        #expect(try await fixture.sessionEvents.next() == .attachCancelled(1))
        _ = try await first?.finish(acceptAlreadyClosed: true)
        first = nil

        var second: NIOAsyncTestingChannel? = await fixture.makeChannel(cmux: fixture.facade)
        try await fixture.connect(second)
        try await fixture.sendHello(second)
        #expect(try await fixture.sessionEvents.next() == .attachStarted(2))
        #expect(try await fixture.sessionEvents.next() == .attachReturned(2))
        try await fixture.sendBattery(second, id: "live")
        #expect(try fixture.response(from: try await second!.waitForOutboundWrite()).id == "live")
        #expect(await fixture.backing.activeSessionCount == 1)

        await fixture.sessions.resumeAttach(1)
        #expect(try await fixture.sessionEvents.next() == .attachReturned(1))
        #expect(try await fixture.sessionEvents.next() == .detached(1))
        #expect(await fixture.backing.activeSessionCount == 1)

        try await second?.close().get()
        #expect(try await fixture.sessionEvents.next() == .detached(2))
        _ = try await second?.finish(acceptAlreadyClosed: true)
        second = nil
        #expect(await fixture.backing.activeSessionCount == 0)
        try await fixture.shutdown()
    }

    @Test func lateRPCCompletionAfterInactiveWritesNothing() async throws {
        let fixture = try LifecycleFixture(sessionModes: [.immediate], suspendedMethods: ["slow.late"])
        var channel: NIOAsyncTestingChannel? = await fixture.makeChannel(cmux: fixture.facade)
        try await fixture.connect(channel)
        try await fixture.sendHello(channel)
        #expect(try await fixture.sessionEvents.next() == .attachStarted(1))
        #expect(try await fixture.sessionEvents.next() == .attachReturned(1))
        try await fixture.sendRPC(channel, id: "late", method: "slow.late")
        #expect(try await fixture.rpcEvents.next() == .started("slow.late"))

        try await channel?.close().get()
        #expect(try await fixture.rpcEvents.next() == .cancelled("slow.late"))
        #expect(try await fixture.sessionEvents.next() == .detached(1))
        await fixture.facade.release("slow.late")
        #expect(try await fixture.rpcEvents.next() == .completed("slow.late"))
        try await fixture.eventLoopBarrier(channel)
        #expect(try await channel?.readOutbound(as: WebSocketFrame.self) == nil)

        _ = try await channel?.finish(acceptAlreadyClosed: true)
        channel = nil
        try await fixture.shutdown()
    }

    @Test func RPCResponsesRemainFIFOAndMalformedRequestKeepsSocketLive() async throws {
        let fixture = try LifecycleFixture(sessionModes: [.immediate], suspendedMethods: ["slow.1"])
        var channel: NIOAsyncTestingChannel? = await fixture.makeChannel(cmux: fixture.facade)
        try await fixture.connect(channel)
        try await fixture.sendHello(channel)
        #expect(try await fixture.sessionEvents.next() == .attachStarted(1))
        #expect(try await fixture.sessionEvents.next() == .attachReturned(1))

        try await fixture.sendRPC(channel, id: "1", method: "slow.1")
        #expect(try await fixture.rpcEvents.next() == .started("slow.1"))
        try await fixture.sendRPC(channel, id: "2", method: "slow.2")
        try await fixture.eventLoopBarrier(channel)
        #expect(await fixture.facade.startedSnapshot() == ["slow.1"])

        await fixture.facade.release("slow.1")
        #expect(try await fixture.rpcEvents.next() == .completed("slow.1"))
        let first = try fixture.response(from: try await channel!.waitForOutboundWrite())
        #expect(first.id == "1")
        #expect(try await fixture.rpcEvents.next() == .started("slow.2"))
        #expect(try await fixture.rpcEvents.next() == .completed("slow.2"))
        let second = try fixture.response(from: try await channel!.waitForOutboundWrite())
        #expect(second.id == "2")

        try await fixture.sendRawRPC(
            channel,
            #"{"id":"bad","method":"surface.subscribe","params":{"workspace_id":"w"}}"#
        )
        try await fixture.sendBattery(channel, id: "battery")
        let malformed = try fixture.response(from: try await channel!.waitForOutboundWrite())
        let battery = try fixture.response(from: try await channel!.waitForOutboundWrite())
        #expect(malformed.id == "bad")
        #expect(malformed.error?.code == "invalid_params")
        #expect(battery.id == "battery")
        #expect(battery.isOk)
        #expect(channel?.isActive == true)

        try await channel?.close().get()
        #expect(try await fixture.sessionEvents.next() == .detached(1))
        _ = try await channel?.finish(acceptAlreadyClosed: true)
        channel = nil
        try await fixture.shutdown()
    }
}

private final class LifecycleFixture: @unchecked Sendable {
    let group: MultiThreadedEventLoopGroup
    let backing: SessionManager
    let sessionEvents: BoundedLifecycleEventProbe<ControllableSessionEvent>
    let rpcEvents: BoundedLifecycleEventProbe<SuspendingRPCEvent>
    let sessions: ControllableWebSocketSessionManager
    let facade: SuspendingLifecycleCMUXFacade
    let store: DeviceStore

    init(
        sessionModes: [ControllableSessionMode],
        suspendedMethods: Set<String> = []
    ) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        backing = SessionManager(reader: FixtureSurfaceReader(), defaultFps: 15, idleFps: 5)
        sessionEvents = BoundedLifecycleEventProbe(eventLoop: group.next())
        rpcEvents = BoundedLifecycleEventProbe(eventLoop: group.next())
        sessions = ControllableWebSocketSessionManager(
            backing: backing,
            modes: sessionModes,
            events: sessionEvents
        )
        facade = SuspendingLifecycleCMUXFacade(
            suspendedMethods: suspendedMethods,
            events: rpcEvents
        )
        store = try DeviceStore.empty()
    }

    func makeHandler(cmux: CMUXFacade) -> WebSocketHandler {
        WebSocketHandler(
            deviceId: "device",
            deviceStore: store,
            sessionLifecycleManager: sessions,
            cmuxClient: cmux
        )
    }

    func makeChannel(cmux: CMUXFacade) async -> NIOAsyncTestingChannel {
        await NIOAsyncTestingChannel(handler: makeHandler(cmux: cmux))
    }

    func connect(_ channel: NIOAsyncTestingChannel?) async throws {
        try await channel?.connect(to: SocketAddress(unixDomainSocketPath: "/fake")).get()
    }

    func sendHello(_ channel: NIOAsyncTestingChannel?) async throws {
        try await sendRawRPC(channel, #"{"deviceId":"device","appVersion":"1","protocolVersion":1}"#)
    }

    func sendRPC(_ channel: NIOAsyncTestingChannel?, id: String, method: String) async throws {
        try await sendRawRPC(channel, #"{"id":"\#(id)","method":"\#(method)","params":{}}"#)
    }

    func sendBattery(_ channel: NIOAsyncTestingChannel?, id: String) async throws {
        try await sendRawRPC(channel, #"{"id":"\#(id)","method":"host.battery","params":{}}"#)
    }

    func sendRawRPC(_ channel: NIOAsyncTestingChannel?, _ text: String) async throws {
        guard let channel else { throw ChannelError.ioOnClosedChannel }
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        try await channel.writeInbound(WebSocketFrame(fin: true, opcode: .text, data: buffer))
    }

    func response(from frame: WebSocketFrame) throws -> RPCResponse {
        let buffer = frame.unmaskedData
        guard let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
            throw WebSocketLifecycleTestError.timeout
        }
        return try JSONDecoder().decode(RPCResponse.self, from: Data(text.utf8))
    }

    func eventLoopBarrier(_ channel: NIOAsyncTestingChannel?) async throws {
        try await channel?.eventLoop.submit {}.get()
    }

    func shutdown() async throws {
        await sessions.resumeAll()
        await facade.releaseAll()
        try await group.shutdownGracefully()
    }
}
