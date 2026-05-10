import XCTest
import NIOCore
import NIOEmbedded
import SharedKit
@testable import CMUXClient

final class CMUXMethodsTests: XCTestCase {
    func testWorkspaceListDecodesSnakeCase() async throws {
        let chan = EmbeddedChannel()
        try chan.pipeline.syncOperations.addHandler(LineFrameDecoder())
        try chan.pipeline.syncOperations.addHandler(LineFrameEncoder())
        let client = CMUXClient(channel: chan, requestTimeout: .seconds(1))

        async let result = client.workspaceList()
        try await Task.sleep(nanoseconds: 5_000_000)
        let outbound: ByteBuffer = try XCTUnwrap(try chan.readOutbound())
        let outString = outbound.getString(at: 0, length: outbound.readableBytes)!
        let regex = try NSRegularExpression(pattern: #"\"id\":\"([^\"]+)\""#)
        let m = regex.firstMatch(in: outString, range: NSRange(outString.startIndex..., in: outString))!
        let outId = String(outString[Range(m.range(at: 1), in: outString)!])
        var resp = ByteBufferAllocator().buffer(capacity: 256)
        resp.writeString(#"{"id":"\#(outId)","result":{"workspaces":[{"id":"w","name":"n","surfaces":[],"last_activity":1000}]}}"#)
        try chan.writeInbound(resp)
        let workspaces = try await result
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces[0].name, "n")
        XCTAssertEqual(workspaces[0].lastActivity, 1000)
    }

    func testSurfaceSendKeyEncodesViaKeyEncoder() async throws {
        let chan = EmbeddedChannel()
        try chan.pipeline.syncOperations.addHandler(LineFrameDecoder())
        try chan.pipeline.syncOperations.addHandler(LineFrameEncoder())
        let client = CMUXClient(channel: chan, requestTimeout: .seconds(1))

        Task { _ = try? await client.surfaceSendKey(workspaceId: "w", surfaceId: "s",
                                                     key: .named("c", modifiers: [.ctrl])) }
        try await Task.sleep(nanoseconds: 5_000_000)
        let outbound: ByteBuffer = try XCTUnwrap(try chan.readOutbound())
        let s = outbound.getString(at: 0, length: outbound.readableBytes)!
        XCTAssertTrue(s.contains("surface.send_key"), s)
        XCTAssertTrue(s.contains("\"key\":\"ctrl+c\""), s)
    }
}
