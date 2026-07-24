import XCTest
import NIOCore
import SharedKit
@testable import CMUXClient

final class EventStreamTests: XCTestCase {
    func testAllCasesRequestIncludesAgentAndHookButNotUnknown() async throws {
        let fix = try await MTELGCmuxFixture.make(requestTimeout: .seconds(2))
        defer { Task { await fix.shutdown() } }

        let stream = EventStream(client: fix.client) { _ in }

        async let startTask = stream.start(categories: EventCategory.allCases)

        let outString = try await fix.awaitRequestLine()
        XCTAssertTrue(outString.contains("\"workspace\""), outString)
        XCTAssertTrue(outString.contains("\"surface\""), outString)
        XCTAssertTrue(outString.contains("\"notification\""), outString)
        XCTAssertTrue(outString.contains("\"system\""), outString)
        XCTAssertTrue(outString.contains("\"agent\""), outString)
        XCTAssertTrue(outString.contains("\"hook\""), outString)
        XCTAssertFalse(outString.contains("\"unknown\""), outString)

        let pattern = #"\"id\":\"([^\"]+)\""#
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(
            regex.firstMatch(in: outString, range: NSRange(outString.startIndex..., in: outString)),
            "no id in: \(outString)")
        let outId = String(outString[Range(match.range(at: 1), in: outString)!])
        try await fix.sendToClient(line: #"{"id":"\#(outId)","result":null}"#)

        _ = await startTask
    }

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

    /// cmux 0.64.12 emits the `cmux-events` protocol: frames carry their own
    /// `id` (a boot-seq) and a `protocol` tag, and have no `type` discriminator.
    /// The old RPC-response-first path in `deliver` would misdecode these as an
    /// RPCResponse (because of the `id`) and silently drop them. This asserts
    /// the new protocol is routed to the event sink.
    func testForwardsCmuxEventsProtocol() async throws {
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

        // Fire-and-forget subscribe: start returns without waiting for an ack.
        await stream.start(categories: [.notification])

        // The cmux-events subscription envelope (no category/name) must be
        // ignored, not delivered as an event.
        try await fix.sendToClient(
            line: #"{"protocol":"cmux-events","subscription_id":"sub-1","boot_id":"B1","heartbeat_interval_seconds":15,"filters":{"categories":["notification"],"names":[]}}"#)

        // A real cmux 0.64.12 event line — carries `id`, `boot_id`, `protocol`.
        try await fix.sendToClient(
            line: #"{"protocol":"cmux-events","boot_id":"B1","id":"B1-2529","category":"notification","name":"notification.cleared","occurred_at":"2026-06-03T00:51:04.730Z","pane_id":null,"payload":{"count":1}}"#)

        for _ in 0..<20 where await sink.count() == 0 {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let count = await sink.count()
        XCTAssertEqual(count, 1, "envelope should be ignored; exactly one event delivered")
        let first = await sink.first()
        XCTAssertEqual(first?.category, .notification)
        XCTAssertEqual(first?.name, "notification.cleared")
    }
}
