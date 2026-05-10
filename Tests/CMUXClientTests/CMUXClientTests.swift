import XCTest
import NIOCore
import NIOEmbedded
import SharedKit
@testable import CMUXClient

final class CMUXClientTests: XCTestCase {
    /// EmbeddedChannel-backed harness so tests don't open real Unix sockets.
    private func makeHarness() -> (EmbeddedChannel, CMUXClient) {
        let chan = EmbeddedChannel()
        try! chan.pipeline.syncOperations.addHandler(LineFrameDecoder())
        try! chan.pipeline.syncOperations.addHandler(LineFrameEncoder())
        let client = CMUXClient(channel: chan, requestTimeout: .seconds(1))
        return (chan, client)
    }

    func testCallEncodesRequestAndResolvesOnResponse() async throws {
        let (chan, client) = makeHarness()
        async let result = client.call(method: "workspace.list", params: .object([:]))

        // Pump one round of EmbeddedChannel I/O.
        try await Task.sleep(nanoseconds: 10_000_000)
        let outbound: ByteBuffer = try XCTUnwrap(try chan.readOutbound())
        let outString = outbound.getString(at: 0, length: outbound.readableBytes)!
        XCTAssertTrue(outString.contains("\"method\":\"workspace.list\""))
        // Extract the UUID id the client generated, echo it back from the fake server.
        let pattern = #"\"id\":\"([^\"]+)\""#
        let regex = try NSRegularExpression(pattern: pattern)
        let match = regex.firstMatch(in: outString, range: NSRange(outString.startIndex..., in: outString))
        let outId = String(outString[Range(match!.range(at: 1), in: outString)!])

        // Inject a server response with the same id (success without `ok`).
        var resp = ByteBufferAllocator().buffer(capacity: 64)
        resp.writeString(#"{"id":"\#(outId)","result":{"workspaces":[]}}"#)
        try chan.writeInbound(resp)

        let value = try await result
        XCTAssertTrue(value.isOk)
    }

    func testTimeoutThrows() async throws {
        let (_, client) = makeHarness()
        do {
            _ = try await client.call(method: "workspace.list", params: .object([:]))
            XCTFail("expected timeout")
        } catch CMUXClientError.timeout {
            // ok
        }
    }

    func testServerPushDispatchesToHandler() async throws {
        let (chan, client) = makeHarness()
        let exp = expectation(description: "push delivered")
        await client.onEventStream { frame in
            if case .event = frame { exp.fulfill() }
        }
        var buf = ByteBufferAllocator().buffer(capacity: 64)
        buf.writeString(#"{"type":"event","category":"system","name":"x","payload":{}}"#)
        try chan.writeInbound(buf)
        await fulfillment(of: [exp], timeout: 1.0)
    }
}
