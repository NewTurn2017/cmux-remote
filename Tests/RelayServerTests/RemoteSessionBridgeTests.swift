import XCTest
import RelayCore
import SharedKit
@testable import RelayServer

final class RemoteSessionBridgeTests: XCTestCase {
    func testBrokerURLConvertsHTTPSAndAppendsRelayRoute() throws {
        let config = RelayConfig.Broker(
            url: "https://relay.example.com/cmux/",
            relayId: "home mac",
            relayToken: "secret"
        )
        XCTAssertEqual(
            try BrokerTunnelClient.webSocketURL(config: config).absoluteString,
            "wss://relay.example.com/cmux/v1/relay/ws?relay_id=home%20mac"
        )
    }

    func testBrokerURLRejectsPlainInternetWebSocket() {
        let config = RelayConfig.Broker(
            url: "ws://relay.example.com",
            relayId: "home-mac",
            relayToken: "secret"
        )
        XCTAssertThrowsError(try BrokerTunnelClient.webSocketURL(config: config)) { error in
            XCTAssertEqual(error as? BrokerTunnelError, .insecureURL)
        }
    }

    func testBrokerURLAllowsPlainLoopbackForLocalTesting() throws {
        let config = RelayConfig.Broker(
            url: "http://127.0.0.1:4398",
            relayId: "local",
            relayToken: "secret"
        )
        XCTAssertEqual(
            try BrokerTunnelClient.webSocketURL(config: config).absoluteString,
            "ws://127.0.0.1:4398/v1/relay/ws?relay_id=local"
        )
    }

    func testBridgeAttachesDispatchesAndClosesSession() async throws {
        let manager = SessionManager(reader: EmptySurfaceReader(), defaultFps: 15, idleFps: 5)
        let recorder = BrokerEnvelopeRecorder()
        let bridge = RemoteSessionBridge(
            sessionManager: manager,
            cmux: NoOpCMUXFacade()
        ) { envelope in
            await recorder.append(envelope)
        }

        await bridge.receive(.open(sessionId: "session-1", deviceId: "authenticated-device"))
        await bridge.receive(.text(
            sessionId: "session-1",
            text: #"{"deviceId":"spoofed-device","appVersion":"1","protocolVersion":1}"#
        ))
        let attachedCount = await manager.activeSessionCount
        XCTAssertEqual(attachedCount, 1)

        await bridge.receive(.text(
            sessionId: "session-1",
            text: #"{"id":"rpc-1","method":"workspace.list","params":{}}"#
        ))
        let sent = await recorder.snapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].type, .sessionText)
        XCTAssertEqual(sent[0].sessionId, "session-1")
        XCTAssertTrue(sent[0].text?.contains(#""id":"rpc-1""#) == true)

        await bridge.receive(.close(sessionId: "session-1"))
        let detachedCount = await manager.activeSessionCount
        let bridgeCount = await bridge.activeSessionCount
        XCTAssertEqual(detachedCount, 0)
        XCTAssertEqual(bridgeCount, 0)
    }

    func testInvalidFirstPhoneFrameClosesOnlyThatBrokerSession() async {
        let manager = SessionManager(reader: EmptySurfaceReader(), defaultFps: 15, idleFps: 5)
        let recorder = BrokerEnvelopeRecorder()
        let bridge = RemoteSessionBridge(
            sessionManager: manager,
            cmux: NoOpCMUXFacade()
        ) { envelope in
            await recorder.append(envelope)
        }

        await bridge.receive(.open(sessionId: "bad", deviceId: "device"))
        await bridge.receive(.text(sessionId: "bad", text: "not-json"))

        let recorded = await recorder.snapshot()
        let bridgeCount = await bridge.activeSessionCount
        XCTAssertEqual(recorded, [.close(sessionId: "bad")])
        XCTAssertEqual(bridgeCount, 0)
    }

    func testBrokerSessionClosesWhenHelloDoesNotArrive() async throws {
        let manager = SessionManager(reader: EmptySurfaceReader(), defaultFps: 15, idleFps: 5)
        let recorder = BrokerEnvelopeRecorder()
        let bridge = RemoteSessionBridge(
            sessionManager: manager,
            cmux: NoOpCMUXFacade()
        ) { envelope in
            await recorder.append(envelope)
        }

        await bridge.receive(.open(sessionId: "silent", deviceId: "device"))
        try await Task.sleep(nanoseconds: 250_000_000)

        let recorded = await recorder.snapshot()
        let bridgeCount = await bridge.activeSessionCount
        XCTAssertEqual(recorded, [.close(sessionId: "silent")])
        XCTAssertEqual(bridgeCount, 0)
    }
}

private struct EmptySurfaceReader: SurfaceReader {
    func read(workspaceId: String, surfaceId: String, lines: Int) async throws -> Screen {
        Screen(rev: 0, rows: [" "], cols: 1, cursor: CursorPos(x: 0, y: 0))
    }
}

private actor BrokerEnvelopeRecorder {
    private var envelopes: [BrokerEnvelope] = []
    func append(_ envelope: BrokerEnvelope) { envelopes.append(envelope) }
    func snapshot() -> [BrokerEnvelope] { envelopes }
}
