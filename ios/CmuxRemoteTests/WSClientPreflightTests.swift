import Foundation
import Testing
@testable import CmuxRemote

@Suite(.timeLimit(.minutes(1)))
struct WSClientPreflightTests {
    @Test
    func reconnectPreflightRunsBeforeCreatingReplacementConnection() async {
        let factory = FakeWSClientConnectionFactory()
        let gate = WSClientReconnectGate()
        let preflight = LockBox(0)
        let client = makeClient(factory: factory, gate: gate) {
            preflight.withValue { $0 += 1 }
        }
        let creations = await factory.creations()
        var creationIterator = creations.makeAsyncIterator()
        let waits = await gate.waits()
        var waitIterator = waits.makeAsyncIterator()

        await client.connect()
        #expect(await creationIterator.next() == 0)
        let first = await factory.connection(at: 0)
        await first.emitClose(code: 1006)
        #expect(await waitIterator.next() == 1)
        await gate.release()
        #expect(await creationIterator.next() == 1)
        #expect(preflight.withValue { $0 } == 1)
        await client.close()
    }

    @Test
    func transientPreflightFailureKeepsReconnectLoopAlive() async {
        let factory = FakeWSClientConnectionFactory()
        let gate = WSClientReconnectGate()
        let attempts = LockBox(0)
        let client = makeClient(factory: factory, gate: gate) {
            let attempt = attempts.withValue { value -> Int in
                value += 1
                return value
            }
            if attempt == 1 { throw URLError(.timedOut) }
        }
        let waits = await gate.waits()
        var waitIterator = waits.makeAsyncIterator()
        let creations = await factory.creations()
        var creationIterator = creations.makeAsyncIterator()

        await client.connect()
        #expect(await creationIterator.next() == 0)
        let first = await factory.connection(at: 0)
        await first.emitClose(code: 1006)
        #expect(await waitIterator.next() == 1)
        await gate.release()
        #expect(await waitIterator.next() == 2)
        await gate.release()

        #expect(await creationIterator.next() == 1)
        #expect(attempts.withValue { $0 } == 2)
        await client.close()
    }

    @Test
    func rejectedBearerPreflightStopsReconnectLoop() async {
        let factory = FakeWSClientConnectionFactory()
        let gate = WSClientReconnectGate()
        let closeEvents = AsyncStream.makeStream(of: Int.self)
        var closeIterator = closeEvents.stream.makeAsyncIterator()
        let client = makeClient(factory: factory, gate: gate) {
            throw AuthError.pairingRemoved
        }
        await client.setOnClose { closeEvents.continuation.yield($0) }
        let waits = await gate.waits()
        var waitIterator = waits.makeAsyncIterator()

        await client.connect()
        let first = await factory.connection(at: 0)
        await first.emitClose(code: 1006)
        #expect(await closeIterator.next() == 1006)
        #expect(await waitIterator.next() == 1)
        await gate.release()

        #expect(await closeIterator.next() == 4401)
        #expect(await factory.connectionCount() == 1)
        await client.close()
    }

    private func makeClient(
        factory: FakeWSClientConnectionFactory,
        gate: WSClientReconnectGate,
        beforeReconnect: @escaping @Sendable () async throws -> Void
    ) -> WSClient {
        WSClient(
            url: URL(string: "ws://relay.example/v1/ws")!,
            headers: [
                "Authorization": "Bearer test-token",
                "Sec-WebSocket-Protocol": "cmuxremote.v1",
            ],
            connectionFactory: factory,
            reconnectDelay: { try await gate.wait(delay: $0) },
            beforeReconnect: beforeReconnect
        )
    }
}
