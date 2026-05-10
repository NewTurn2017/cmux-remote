import XCTest
import NIOCore
import NIOEmbedded
import SharedKit
@testable import CMUXClient

final class EventStreamTests: XCTestCase {
    func testForwardsEvents() async throws {
        let chan = EmbeddedChannel()
        try chan.pipeline.syncOperations.addHandler(LineFrameDecoder())
        try chan.pipeline.syncOperations.addHandler(LineFrameEncoder())
        let client = CMUXClient(channel: chan, requestTimeout: .seconds(1))

        actor Sink {
            var seen: [EventFrame] = []
            func append(_ frame: EventFrame) { seen.append(frame) }
            func count() -> Int { seen.count }
            func first() -> EventFrame? { seen.first }
        }
        let sink = Sink()
        let stream = EventStream(client: client) { frame in
            Task { await sink.append(frame) }
        }

        async let startTask = stream.start(categories: [.notification])

        // Pump one round to send the request
        try await Task.sleep(nanoseconds: 10_000_000)
        let outbound: ByteBuffer = try XCTUnwrap(try chan.readOutbound())
        let outString = outbound.getString(at: 0, length: outbound.readableBytes)!

        // Extract the UUID id and echo it back as a success response
        let pattern = #"\"id\":\"([^\"]+)\""#
        let regex = try NSRegularExpression(pattern: pattern)
        let match = regex.firstMatch(in: outString, range: NSRange(outString.startIndex..., in: outString))
        let outId = String(outString[Range(match!.range(at: 1), in: outString)!])

        // Inject a server response with the same id (success without `ok`)
        var resp = ByteBufferAllocator().buffer(capacity: 64)
        resp.writeString(#"{"id":"\#(outId)","result":null}"#)
        try chan.writeInbound(resp)

        // Wait for start to complete
        _ = try await startTask

        // Now send an event
        var buf = ByteBufferAllocator().buffer(capacity: 128)
        buf.writeString(#"{"type":"event","category":"notification","name":"notification.created","payload":{"id":"n-1"}}"#)
        try chan.writeInbound(buf)
        try await Task.sleep(nanoseconds: 30_000_000)
        let count = await sink.count()
        XCTAssertEqual(count, 1)
        let first = await sink.first()
        XCTAssertEqual(first?.name, "notification.created")
    }
}
