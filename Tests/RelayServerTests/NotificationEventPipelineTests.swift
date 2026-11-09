import Foundation
import XCTest
import SharedKit
@testable import RelayServer

final class NotificationEventPipelineTests: XCTestCase {
    func testRoutesDropTheSocketAuditAndPushOnlyCards() throws {
        XCTAssertEqual(NotificationEventPipeline.route(try NotificationFixture.event("notification.requested")), .drop)
        XCTAssertEqual(NotificationEventPipeline.route(try NotificationFixture.event("notification.created")), .broadcastAndPush)
        XCTAssertEqual(NotificationEventPipeline.route(try NotificationFixture.event("notification.read")), .broadcast)
        XCTAssertEqual(NotificationEventPipeline.route(try NotificationFixture.event("notification.removed")), .broadcast)
        XCTAssertEqual(NotificationEventPipeline.route(EventFrame(
            category: .notification, name: "notification.clear_requested", payload: .object([:])
        )), .broadcast)
        XCTAssertEqual(NotificationEventPipeline.route(EventFrame(
            category: .workspace, name: "workspace.updated", payload: .object([:])
        )), .broadcast)
        XCTAssertEqual(NotificationEventPipeline.route(EventFrame(
            category: .hook,
            name: "codex.permission_prompt",
            payload: .object(["workspace_id": .string("w1"), "source": .string("Codex"), "message": .string("approval required")])
        )), .broadcastAndPush)
    }

    func testKeepsCmuxOrderAndHoldsLaterEventsWhileContentLoads() async throws {
        let gate = NotificationGate()
        let enrichStarted = expectation(description: "enrichment started")
        let broadcasts = NotificationFrameRecorder()
        let pushes = NotificationFrameRecorder()
        let filledPayload = try NotificationFixture.listResult()
        let pipeline = NotificationEventPipeline(
            enrich: { event in
                guard event.name == "notification.created" else { return event }
                enrichStarted.fulfill()
                await gate.wait()
                return Self.filled(event, from: filledPayload)
            },
            broadcast: { await broadcasts.record($0) },
            push: { await pushes.record(.event($0)) }
        )

        for event in try NotificationFixture.events() {
            pipeline.submit(event)
        }
        await fulfillment(of: [enrichStarted], timeout: 5)
        let heldFrames = await broadcasts.frames
        XCTAssertTrue(heldFrames.isEmpty, "events behind a loading notification must wait")

        await gate.open()
        await awaitBounded("three events broadcast") { await broadcasts.waitUntil(count: 3) }
        await awaitBounded("created pushed") { await pushes.waitUntil(count: 1) }
        await pipeline.finish()

        let names = await broadcasts.eventNames
        XCTAssertEqual(names, ["notification.created", "notification.read", "notification.removed"])
        let pushed = await pushes.eventNames
        XCTAssertEqual(pushed, ["notification.created"])
        guard case .event(let created)? = await broadcasts.frames.first,
              case .object(let payload) = created.payload
        else { return XCTFail("created event expected first") }
        XCTAssertEqual(payload["title"], .string("Claude Code"))
    }

    func testUnfilledCreatedIsStillForwardedInOrder() async throws {
        let broadcasts = NotificationFrameRecorder()
        let pipeline = NotificationEventPipeline(
            enrich: { $0 },
            broadcast: { await broadcasts.record($0) },
            push: { _ in }
        )

        for event in try NotificationFixture.events() {
            pipeline.submit(event)
        }
        await pipeline.finish()

        let names = await broadcasts.eventNames
        XCTAssertEqual(names, ["notification.created", "notification.read", "notification.removed"])
        guard case .event(let created)? = await broadcasts.frames.first,
              case .object(let payload) = created.payload
        else { return XCTFail("created event expected first") }
        XCTAssertEqual(payload["title"], .null)
    }

    private static func filled(_ event: EventFrame, from list: JSONValue) -> EventFrame {
        guard case .object(let payload) = event.payload,
              case .object(let result) = list,
              case .array(let items)? = result["notifications"],
              case .object(let item)? = items.first,
              case .string(let title)? = item["title"]
        else { return event }
        var filledEvent = event
        filledEvent.payload = .object(NotificationContentEnricher.filled(payload, with: .init(title: title)))
        return filledEvent
    }
}
