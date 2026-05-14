import XCTest
import SharedKit
@testable import CmuxRemote

final class RPCClientTests: XCTestCase {
    func testCallReturnsOnMatchingId() async throws {
        let stub = StubWS()
        let rpc = RPCClient(transport: stub)
        async let result = rpc.call(method: "workspace.list", params: .object([:]))
        try await Task.sleep(nanoseconds: 5_000_000)
        let outbox = await stub.outbox
        let text = try XCTUnwrap(outbox.last)
        XCTAssertTrue(text.contains("workspace.list"))
        let regex = try NSRegularExpression(pattern: #"\"id\":\"([^\"]+)\""#)
        let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let id = String(text[Range(match.range(at: 1), in: text)!])
        await rpc.handleIncoming(text: #"{"id":"\#(id)","result":{"workspaces":[]}}"#)
        let response = try await result
        XCTAssertTrue(response.isOk)
    }

    func testPushFrameDispatchedToHandler() async {
        let rpc = RPCClient(transport: StubWS())
        let saw = LockBox(0)
        await rpc.onPush { _ in saw.withValue { $0 += 1 } }
        await rpc.handleIncoming(text: #"{"type":"event","category":"system","name":"x","payload":{}}"#)
        XCTAssertEqual(saw.withValue { $0 }, 1)
    }

    func testCallTimesOutWithoutResponse() async throws {
        let rpc = RPCClient(transport: StubWS(), timeoutNanoseconds: 1_000_000)
        do {
            _ = try await rpc.call(method: "workspace.list", params: .object([:]))
            XCTFail("expected timeout")
        } catch RPCClientError.timeout {}
    }
}

actor StubWS: RPCTransport {
    private(set) var outbox: [String] = []
    func send(text: String) async { outbox.append(text) }
    func close() async {}
}
