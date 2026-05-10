import XCTest
import NIOCore
import SharedKit
@testable import CMUXClient

final class EventStreamTests: XCTestCase {
    func testForwardsEvents() async throws {
        let fix = try await MTELGCmuxFixture.make(requestTimeout: .seconds(2))
        defer { Task { await fix.shutdown() } }

        actor Sink {
            var seen: [EventFrame] = []
            func append(_ frame: EventFrame) { seen.append(frame) }
            func count() -> Int { seen.count }
            func first() -> EventFrame? { seen.first }
        }
        let sink = Sink()
        let stream = EventStream(client: fix.client) { frame in
            Task { await sink.append(frame) }
        }

        async let startTask = stream.start(categories: [.notification])

        let outString = try await fix.awaitRequestLine()
        let pattern = #"\"id\":\"([^\"]+)\""#
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(
            regex.firstMatch(in: outString, range: NSRange(outString.startIndex..., in: outString)),
            "no id in: \(outString)")
        let outId = String(outString[Range(match.range(at: 1), in: outString)!])

        try await fix.sendToClient(line: #"{"id":"\#(outId)","result":null}"#)

        _ = await startTask

        try await fix.sendToClient(
            line: #"{"type":"event","category":"notification","name":"notification.created","payload":{"id":"n-1"}}"#)

        // Allow the inbound dispatch + Task hop to land.
        for _ in 0..<20 where await sink.count() == 0 {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let count = await sink.count()
        XCTAssertEqual(count, 1)
        let first = await sink.first()
        XCTAssertEqual(first?.name, "notification.created")
    }
}
