import XCTest
import SharedKit
@testable import RelayServer
@testable import RelayCore

final class WebSocketHandlerTests: XCTestCase {

    // MARK: - Hello flow

    func testHelloMissedReturnsClose() async {
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        let actions = await m.helloMissed()
        XCTAssertEqual(actions, [.close])
    }

    func testValidHelloEmitsAttach() async {
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        let json = #"{"deviceId":"d-7","appVersion":"1.0.0","protocolVersion":1}"#
        let actions = await m.processText(json)
        XCTAssertEqual(actions, [.attachSession(deviceId: "d-7")])
    }

    func testInvalidFirstFrameClosesBeforeHello() async {
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        let actions = await m.processText("not json")
        XCTAssertEqual(actions, [.close])
    }

    func testFirstFrameWrongShapeClosesBeforeHello() async {
        // Looks like JSON but isn't a HelloFrame.
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        let actions = await m.processText(#"{"id":"1","method":"workspace.list","params":{}}"#)
        XCTAssertEqual(actions, [.close])
    }

    func testHelloMissedAfterHelloIsNoop() async {
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)
        let actions = await m.helloMissed()
        XCTAssertEqual(actions, [])
    }

    // MARK: - RPC dispatch

    func testRPCDispatchesToFacade() async {
        let cmux = RecordingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"1","method":"workspace.list","params":{}}"#)

        let calls = await cmux.snapshot()
        XCTAssertEqual(calls.map(\.method), ["workspace.list"])
        XCTAssertEqual(actions.count, 1)
        guard case .sendText(let s) = actions[0] else {
            return XCTFail("expected sendText, got \(actions[0])")
        }
        XCTAssertTrue(s.contains(#""id":"1""#), "missing id: \(s)")
        XCTAssertTrue(s.contains(#""ok":true"#), "missing ok=true: \(s)")
    }

    func testRPCErrorYieldsErrorResponse() async {
        let cmux = ThrowingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"7","method":"surface.send_text","params":{}}"#)
        XCTAssertEqual(actions.count, 1)
        guard case .sendText(let s) = actions[0] else {
            return XCTFail("expected sendText, got \(actions[0])")
        }
        XCTAssertTrue(s.contains(#""ok":false"#), "missing ok=false: \(s)")
        XCTAssertTrue(s.contains(#""code":"internal_error""#), "missing code: \(s)")
    }

    func testGarbageAfterHelloIsIgnored() async {
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)
        let actions = await m.processText("not json")
        XCTAssertEqual(actions, [])
    }

    func testSurfaceSubscribeBecomesRelayActionWithoutCmuxDispatch() async {
        let cmux = RecordingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"9","method":"surface.subscribe","params":{"workspace_id":"w","surface_id":"s","fps":15}}"#)

        let calls = await cmux.snapshot()
        XCTAssertEqual(calls, [])
        XCTAssertEqual(actions, [.subscribe(responseId: "9", workspaceId: "w", surfaceId: "s", lines: 200)])
    }

    func testSurfaceUnsubscribeBecomesRelayActionWithoutCmuxDispatch() async {
        let cmux = RecordingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"10","method":"surface.unsubscribe","params":{"surface_id":"s"}}"#)

        let calls = await cmux.snapshot()
        XCTAssertEqual(calls, [])
        XCTAssertEqual(actions, [.unsubscribe(responseId: "10", surfaceId: "s")])
    }
}

// MARK: - Test doubles

final class NoOpCMUXFacade: CMUXFacade {
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        .object([:])
    }
}

actor RecordingCMUXFacade: CMUXFacade {
    struct Call: Equatable, Sendable { let method: String }
    private var calls: [Call] = []
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        calls.append(.init(method: method))
        return .object([:])
    }
    func snapshot() -> [Call] { calls }
}

final class ThrowingCMUXFacade: CMUXFacade {
    struct Boom: Error {}
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        throw Boom()
    }
}
