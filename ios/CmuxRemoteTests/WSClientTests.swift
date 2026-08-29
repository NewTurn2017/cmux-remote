import Foundation
import Testing
@testable import CmuxRemote

@Suite(.timeLimit(.minutes(1)))
struct WSClientTests {
    @Test
    func resumeDoesNotPublishOpenOrSendHelloBeforeDelegateOpen() async {
        let factory = FakeWSClientConnectionFactory()
        let openEvents = AsyncStream.makeStream(of: Void.self)
        let client = makeClient(factory: factory)
        await client.setOnOpen {
            openEvents.continuation.yield()
            await client.send(text: "hello")
        }

        await client.connect()
        let connection = await factory.connection(at: 0)
        openEvents.continuation.finish()
        var openCount = 0
        for await _ in openEvents.stream {
            openCount += 1
        }

        #expect(await connection.observedResumeCount() == 1)
        #expect(openCount == 0, "resume must not publish negotiated-open")
        #expect(await connection.observedSentTexts().isEmpty, "hello must wait for didOpenWithProtocol")
        #expect(await factory.headers(at: 0)["Authorization"] == "Bearer test-token")
        #expect(await factory.protocols(at: 0) == ["cmuxremote.v1"])
        await client.close()
    }

    @Test
    func directSendBeforeDelegateOpenDoesNotReachTransport() async {
        let factory = FakeWSClientConnectionFactory()
        let client = makeClient(factory: factory)

        await client.connect()
        let connection = await factory.connection(at: 0)
        await client.send(text: "workspace.list")

        #expect(await connection.observedSentTexts().isEmpty, "pre-open RPC must remain queued")
        await client.close()
    }

    @Test
    func queuedMessagesPreserveFIFOOrderAndDuplicates() async {
        let factory = FakeWSClientConnectionFactory()
        let client = makeClient(factory: factory)
        await client.connect()
        let connection = await factory.connection(at: 0)

        await client.send(text: "workspace.list")
        await client.send(text: "workspace.list")
        await client.send(text: "host.status")
        #expect(await connection.observedSentTexts().isEmpty)

        await connection.emitOpen()
        #expect(await connection.observedSentTexts() == ["workspace.list", "workspace.list", "host.status"])
        await client.close()
    }

    @Test
    func asyncOpenHookCompletesBeforeQueuedRPCFlush() async {
        let factory = FakeWSClientConnectionFactory()
        let hookGate = WSClientOpenHookGate()
        let client = makeClient(factory: factory)
        await client.setOnOpen {
            await client.send(text: "hello")
            await hookGate.wait()
        }
        await client.connect()
        let connection = await factory.connection(at: 0)
        await client.send(text: "workspace.list")
        let hookStarts = await hookGate.starts()
        var hookStartIterator = hookStarts.makeAsyncIterator()

        let openTask = Task { await connection.emitOpen() }
        await hookStartIterator.next()
        #expect(await connection.observedSentTexts() == ["hello"])

        await hookGate.release()
        await openTask.value
        #expect(await connection.observedSentTexts() == ["hello", "workspace.list"])
        await client.close()
    }

    @Test
    func replacementDuringAsyncOpenHookCannotFlushOldQueue() async {
        let factory = FakeWSClientConnectionFactory()
        let hookGate = WSClientOpenHookGate()
        let client = makeClient(factory: factory)
        await client.setOnOpen { await hookGate.wait() }
        await client.connect()
        let staleConnection = await factory.connection(at: 0)
        await client.send(text: "old-generation")
        let hookStarts = await hookGate.starts()
        var hookStartIterator = hookStarts.makeAsyncIterator()

        let staleOpenTask = Task { await staleConnection.emitOpen() }
        await hookStartIterator.next()
        await client.connect()
        let currentConnection = await factory.connection(at: 1)
        await hookGate.release()
        await staleOpenTask.value

        #expect(await staleConnection.observedSentTexts().isEmpty)
        #expect(await currentConnection.observedSentTexts().isEmpty)
        await client.close()
    }

    @Test
    func currentDelegateOpenPublishesExactlyOnceAndMakesHelloEligible() async {
        let factory = FakeWSClientConnectionFactory()
        let openEvents = AsyncStream.makeStream(of: Void.self)
        let client = makeClient(factory: factory)
        await client.setOnOpen {
            openEvents.continuation.yield()
            await client.send(text: "hello")
        }
        await client.connect()
        let connection = await factory.connection(at: 0)

        await connection.emitOpen()
        await connection.emitOpen()
        openEvents.continuation.finish()
        var openCount = 0
        for await _ in openEvents.stream {
            openCount += 1
        }

        #expect(openCount == 1)
        #expect(await connection.observedSentTexts() == ["hello"])
        await client.close()
    }

    @Test
    func publicReplacementDropsOldQueueAndStaleOpenCannotFlush() async {
        let factory = FakeWSClientConnectionFactory()
        let client = makeClient(factory: factory)

        await client.connect()
        let staleConnection = await factory.connection(at: 0)
        await client.send(text: "old-generation")
        await client.connect()
        let currentConnection = await factory.connection(at: 1)
        await client.send(text: "current-generation")

        await staleConnection.emitOpen()
        #expect(await staleConnection.observedSentTexts().isEmpty)
        #expect(await currentConnection.observedSentTexts().isEmpty)

        await currentConnection.emitOpen()
        #expect(await currentConnection.observedSentTexts() == ["current-generation"])
        await client.close()
    }

    @Test
    func staleGenerationOpenAndCloseDoNotAffectReplacementConnection() async {
        let factory = FakeWSClientConnectionFactory()
        let openEvents = AsyncStream.makeStream(of: Void.self)
        let closeEvents = AsyncStream.makeStream(of: Int.self)
        let client = makeClient(factory: factory)
        await client.setOnOpen { openEvents.continuation.yield() }
        await client.setOnClose { closeEvents.continuation.yield($0) }

        await client.connect()
        let staleConnection = await factory.connection(at: 0)
        await client.connect()
        let currentConnection = await factory.connection(at: 1)

        await staleConnection.emitOpen()
        await staleConnection.emitClose(code: 1006)
        await currentConnection.emitOpen()
        openEvents.continuation.finish()
        closeEvents.continuation.finish()
        var openCount = 0
        for await _ in openEvents.stream {
            openCount += 1
        }
        var observedCloseCodes: [Int] = []
        for await code in closeEvents.stream {
            observedCloseCodes.append(code)
        }

        #expect(openCount == 1)
        #expect(observedCloseCodes.isEmpty)
        #expect(await factory.connectionCount() == 2)
        await client.close()
    }

    @Test
    func closeBeforeDelegateOpenDropsQueueAndIgnoresLateCallbacks() async {
        let factory = FakeWSClientConnectionFactory()
        let openEvents = AsyncStream.makeStream(of: Void.self)
        let closeEvents = AsyncStream.makeStream(of: Int.self)
        let client = makeClient(factory: factory)
        await client.setOnOpen { openEvents.continuation.yield() }
        await client.setOnClose { closeEvents.continuation.yield($0) }

        await client.connect()
        let staleConnection = await factory.connection(at: 0)
        await client.send(text: "must-drop")
        await client.close()
        await staleConnection.emitOpen()
        await staleConnection.emitClose(code: 1006)

        await client.connect()
        let currentConnection = await factory.connection(at: 1)
        await currentConnection.emitOpen()
        openEvents.continuation.finish()
        closeEvents.continuation.finish()
        var openCount = 0
        for await _ in openEvents.stream {
            openCount += 1
        }
        var observedCloseCodes: [Int] = []
        for await code in closeEvents.stream {
            observedCloseCodes.append(code)
        }

        #expect(openCount == 1)
        #expect(observedCloseCodes.isEmpty)
        #expect(await staleConnection.observedSentTexts().isEmpty)
        #expect(await currentConnection.observedSentTexts().isEmpty)
        await client.close()
    }

    @Test
    func reconnectBeforeOpenPreservesQueueWithoutDuplicates() async {
        let factory = FakeWSClientConnectionFactory()
        let gate = WSClientReconnectGate()
        let client = makeClient(factory: factory, gate: gate)
        let creations = await factory.creations()
        var creationIterator = creations.makeAsyncIterator()
        let waits = await gate.waits()
        var waitIterator = waits.makeAsyncIterator()

        await client.connect()
        #expect(await creationIterator.next() == 0)
        let first = await factory.connection(at: 0)
        await client.send(text: "workspace.list")
        await client.send(text: "workspace.list")
        await first.emitClose(code: 1006)
        #expect(await waitIterator.next() == 1.0)

        await gate.release()
        #expect(await creationIterator.next() == 1)
        let second = await factory.connection(at: 1)
        await second.emitOpen()
        await second.emitOpen()

        #expect(await first.observedSentTexts().isEmpty)
        #expect(await second.observedSentTexts() == ["workspace.list", "workspace.list"])
        await client.close()
    }

    @Test
    func replacementJoinsOldReceiveLoopBeforeStartingNewLoop() async {
        let factory = FakeWSClientConnectionFactory()
        let activities = await factory.receiveActivities()
        var activityIterator = activities.makeAsyncIterator()
        let client = makeClient(factory: factory)

        await client.connect()
        #expect(await activityIterator.next() == 1)
        await client.connect()
        #expect(await activityIterator.next() == 0)
        #expect(await activityIterator.next() == 1)
        #expect(await factory.maximumActiveReceiveCount() == 1)

        await client.close()
        #expect(await activityIterator.next() == 0)
    }

    @Test
    func sendFailureAndTransportCloseNotifyOnceAndReconnectOnce() async {
        let factory = FakeWSClientConnectionFactory()
        let gate = WSClientReconnectGate()
        let closeEvents = AsyncStream.makeStream(of: Int.self)
        let client = makeClient(factory: factory, gate: gate)
        await client.setOnClose { closeEvents.continuation.yield($0) }
        let creations = await factory.creations()
        var creationIterator = creations.makeAsyncIterator()
        let waits = await gate.waits()
        var waitIterator = waits.makeAsyncIterator()

        await client.connect()
        #expect(await creationIterator.next() == 0)
        let connection = await factory.connection(at: 0)
        await connection.emitOpen()
        await connection.failNextSend()
        await client.send(text: "workspace.list")
        await connection.emitClose(code: 1006)
        await connection.emitClose(code: 1006)
        #expect(await waitIterator.next() == 1.0)

        closeEvents.continuation.finish()
        var observedCloseCodes: [Int] = []
        for await code in closeEvents.stream {
            observedCloseCodes.append(code)
        }
        #expect(observedCloseCodes == [-1])

        await gate.release()
        #expect(await creationIterator.next() == 1)
        #expect(await factory.connectionCount() == 2)
        await client.close()
    }

    @Test
    func currentCloseTriggersExactlyOneReconnectAfterGateRelease() async {
        let factory = FakeWSClientConnectionFactory()
        let gate = WSClientReconnectGate()
        let closeEvents = AsyncStream.makeStream(of: Int.self)
        let client = makeClient(factory: factory, gate: gate)
        await client.setOnClose { closeEvents.continuation.yield($0) }
        let creations = await factory.creations()
        var creationIterator = creations.makeAsyncIterator()
        let waits = await gate.waits()
        var waitIterator = waits.makeAsyncIterator()

        await client.connect()
        #expect(await creationIterator.next() == 0)
        let connection = await factory.connection(at: 0)
        await connection.emitClose(code: 1006)
        await connection.emitClose(code: 1006)

        #expect(await waitIterator.next() == 1.0)
        #expect(await factory.connectionCount() == 1)
        closeEvents.continuation.finish()
        var observedCloseCodes: [Int] = []
        for await code in closeEvents.stream {
            observedCloseCodes.append(code)
        }
        #expect(observedCloseCodes == [1006])

        await gate.release()
        #expect(await creationIterator.next() == 1)
        #expect(await factory.connectionCount() == 2)
        await client.close()
    }

    @Test
    func reconnectBackoffResetsOnlyAfterCurrentDelegateOpen() async {
        let factory = FakeWSClientConnectionFactory()
        let gate = WSClientReconnectGate()
        let client = makeClient(factory: factory, gate: gate)
        let creations = await factory.creations()
        var creationIterator = creations.makeAsyncIterator()
        let waits = await gate.waits()
        var waitIterator = waits.makeAsyncIterator()

        await client.connect()
        #expect(await creationIterator.next() == 0)
        let first = await factory.connection(at: 0)
        await first.emitClose(code: 1006)
        #expect(await waitIterator.next() == 1.0)
        await gate.release()
        #expect(await creationIterator.next() == 1)

        let second = await factory.connection(at: 1)
        await second.emitClose(code: 1006)
        #expect(await waitIterator.next() == 2.0)
        await gate.release()
        #expect(await creationIterator.next() == 2)

        let third = await factory.connection(at: 2)
        await third.emitOpen()
        await third.emitClose(code: 1006)
        #expect(await waitIterator.next() == 1.0)
        await gate.release()
        #expect(await creationIterator.next() == 3)
        await client.close()
    }

    private func makeClient(
        factory: FakeWSClientConnectionFactory,
        gate: WSClientReconnectGate? = nil
    ) -> WSClient {
        WSClient(
            url: URL(string: "ws://relay.example/v1/ws")!,
            headers: [
                "Authorization": "Bearer test-token",
                "Sec-WebSocket-Protocol": "cmuxremote.v1",
            ],
            connectionFactory: factory,
            reconnectDelay: { delay in
                if let gate {
                    try await gate.wait(delay: delay)
                }
            }
        )
    }
}
