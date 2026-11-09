import XCTest
@testable import SharedKit

final class InboxNotificationTests: XCTestCase {
    func testBuildsRecordFromPartialNotificationEvent() {
        let event = EventFrame(
            category: .notification,
            name: "notification.created",
            payload: .object([
                "id": .string("n-partial"),
                "workspace_id": .string("w1"),
                "message": .string("새 알림이 도착했습니다."),
            ])
        )

        let record = InboxNotification.record(from: event, now: 42)

        XCTAssertEqual(record?.id, "n-partial")
        XCTAssertEqual(record?.workspaceId, "w1")
        XCTAssertEqual(record?.title, "cmux notification")
        XCTAssertEqual(record?.body, "새 알림이 도착했습니다.")
        XCTAssertEqual(record?.threadId, "workspace-w1")
    }

    func testBuildsNeedsInputRecordAndStableSyntheticId() {
        let event = EventFrame(
            category: .hook,
            name: "codex.permission_prompt",
            payload: .object([
                "workspace_id": .string("w2"),
                "surface_id": .string("s2"),
                "source": .string("Codex"),
                "message": .string("approval required"),
            ])
        )

        let first = InboxNotification.record(from: event, now: 42)
        let second = InboxNotification.record(from: event, now: 99)

        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(first?.title, "Codex needs input")
        XCTAssertEqual(first?.body, "approval required")
        XCTAssertEqual(first?.surfaceId, "s2")
    }

    func testIgnoresGenericWorkspaceApprovalNoise() {
        let event = EventFrame(
            category: .workspace,
            name: "workspace.updated",
            payload: .object([
                "workspace_id": .string("w3"),
                "source": .string("billing"),
                "message": .string("approval required"),
            ])
        )

        XCTAssertFalse(InboxNotification.isInboxEvent(event))
        XCTAssertNil(InboxNotification.record(from: event, now: 42))
    }

    // MARK: - cmux build 113 notification events (synthetic fixture, real key shape)

    func testRedactedCreatedBecomesCardWithFallbackTitleAndNoBody() throws {
        let event = try InboxFixture.event("notification.created")

        guard case .card(let card) = InboxNotification.effect(for: event, now: 42) else {
            return XCTFail("notification.created must make a card")
        }

        XCTAssertTrue(card.isCmuxNotification)
        XCTAssertFalse(card.requiresUserInput)
        XCTAssertFalse(card.isRead)
        XCTAssertEqual(card.replacedIds, ["N-0000"])
        XCTAssertEqual(card.record.id, "N-0001")
        XCTAssertEqual(card.record.workspaceId, "WS-AAAA")
        XCTAssertEqual(card.record.surfaceId, "SF-1111")
        XCTAssertEqual(card.record.title, InboxNotification.fallbackTitle)
        XCTAssertEqual(card.record.body, "")
        XCTAssertNil(card.record.subtitle)
    }

    func testFilledCreatedShowsContentThroughTheFallbackDecoder() throws {
        let event = try InboxFixture.filledCreated()

        guard case .card(let card) = InboxNotification.effect(for: event, now: 42) else {
            return XCTFail("filled notification.created must make a card")
        }

        XCTAssertEqual(card.record.id, "N-0001")
        XCTAssertEqual(card.record.title, "Claude Code")
        XCTAssertEqual(card.record.subtitle, "agent-lab")
        XCTAssertEqual(card.record.body, "Claude is waiting for your input")
        XCTAssertEqual(card.record.threadId, "workspace-WS-AAAA")
        XCTAssertTrue(card.requiresUserInput)
        // 1.1.4 apps run the same `record(from:)` path, so they show the filled content too.
        XCTAssertEqual(InboxNotification.record(from: event, now: 42), card.record)
    }

    func testFilledCreatedWithoutSubtitleFallsBackToTabTitle() throws {
        var event = try InboxFixture.filledCreated()
        guard case .object(var payload) = event.payload else { return XCTFail("object payload") }
        payload["subtitle"] = .null
        event.payload = .object(payload)

        XCTAssertEqual(InboxNotification.record(from: event, now: 42)?.subtitle, "claude")
    }

    func testCreatedThatIsAlreadyReadCarriesReadState() throws {
        var event = try InboxFixture.event("notification.created")
        guard case .object(var payload) = event.payload else { return XCTFail("object payload") }
        payload["is_read"] = .bool(true)
        event.payload = .object(payload)

        guard case .card(let card) = InboxNotification.effect(for: event, now: 42) else {
            return XCTFail("card expected")
        }
        XCTAssertTrue(card.isRead)
    }

    func testRequestedSocketAuditIsIgnored() throws {
        let event = try InboxFixture.event("notification.requested")

        XCTAssertEqual(InboxNotification.effect(for: event, now: 42), .ignore)
        XCTAssertFalse(InboxNotification.isInboxEvent(event))
        XCTAssertNil(InboxNotification.record(from: event, now: 42))
    }

    func testReadAndRemovedChangeExistingCards() throws {
        XCTAssertEqual(
            InboxNotification.effect(for: try InboxFixture.event("notification.read"), now: 42),
            .markRead(ids: ["N-0001"])
        )
        XCTAssertEqual(
            InboxNotification.effect(for: try InboxFixture.event("notification.removed"), now: 42),
            .remove(ids: ["N-0001"])
        )
        XCTAssertNil(InboxNotification.record(from: try InboxFixture.event("notification.read"), now: 42))
    }

    func testStateEventsWithoutIdAndOtherNotificationEventsAreIgnored() {
        for name in ["notification.read", "notification.removed", "notification.clear_requested", "notification.updated"] {
            let event = EventFrame(
                category: .notification,
                name: name,
                payload: .object(["workspace_id": .string("WS-AAAA")])
            )
            XCTAssertEqual(InboxNotification.effect(for: event, now: 42), .ignore, name)
        }
    }

    func testNotificationStateEventWithNeedsInputTextIsNotACard() {
        let event = EventFrame(
            category: .notification,
            name: "notification.clear_requested",
            payload: .object([
                "workspace_id": .string("WS-AAAA"),
                "title": .string("Claude Code"),
                "body": .string("Claude is waiting for your input"),
            ])
        )

        XCTAssertEqual(InboxNotification.effect(for: event, now: 42), .ignore)
    }

    func testAgentNeedsInputEventStillMakesAUserInputCard() {
        let event = EventFrame(
            category: .hook,
            name: "codex.permission_prompt",
            payload: .object([
                "workspace_id": .string("w2"),
                "source": .string("Codex"),
                "message": .string("approval required"),
            ])
        )

        guard case .card(let card) = InboxNotification.effect(for: event, now: 42) else {
            return XCTFail("needs-input card expected")
        }
        XCTAssertFalse(card.isCmuxNotification)
        XCTAssertTrue(card.requiresUserInput)
        XCTAssertEqual(card.record.title, "Codex needs input")
    }
}

/// Event payloads copied from the lane fixture `cmux-notification-events.json` (sha256
/// c8188d9cc0e8d509; key shape measured on cmux build 113, values invented). Top-level
/// envelope keys the relay does not decode are trimmed.
enum InboxFixture {
    struct ShapeError: Error {}

    static let eventsJSON = #"""
    [
     {"type":"event","category":"notification","name":"notification.requested","source":"socket.v2","id":"evt-1","seq":101,"workspace_id":"WS-AAAA","surface_id":"SF-1111",
      "payload":{"method":"notification.create_for_target","params":{"title":null,"title_length":8,"subtitle":null,"subtitle_length":8,"body":null,"body_length":8,"redacted_fields":["title","subtitle","body"],"effects":{"desktop":false},"surface_id":"SF-1111","workspace_id":"WS-AAAA"},"result":{"id":"N-0001","surface_id":"SF-1111","surface_ref":"surface:1","window_id":"WIN-1","window_ref":"window:1","workspace_id":"WS-AAAA","workspace_ref":"workspace:1"}}},
     {"type":"event","category":"notification","name":"notification.created","source":"notification.store","id":"evt-2","seq":102,"workspace_id":"WS-AAAA","surface_id":"SF-1111",
      "payload":{"notification_id":"N-0001","workspace_id":"WS-AAAA","surface_id":"SF-1111","created_at":"2026-11-09T02:13:00Z","is_read":false,"delivery":"store","replaced_notification_ids":["N-0000"],"title":null,"title_length":11,"subtitle":null,"subtitle_length":7,"body":null,"body_length":32,"redacted_fields":["title","subtitle","body"]}},
     {"type":"event","category":"notification","name":"notification.read","source":"notification.store","id":"evt-3","seq":103,"workspace_id":"WS-AAAA","surface_id":"SF-1111",
      "payload":{"notification_id":"N-0001","workspace_id":"WS-AAAA","surface_id":"SF-1111","created_at":"2026-11-09T02:13:00Z","is_read":true,"title":null,"title_length":11,"subtitle":null,"subtitle_length":7,"body":null,"body_length":32,"redacted_fields":["title","subtitle","body"]}},
     {"type":"event","category":"notification","name":"notification.removed","source":"notification.store","id":"evt-4","seq":104,"workspace_id":"WS-AAAA","surface_id":"SF-1111",
      "payload":{"notification_id":"N-0001","workspace_id":"WS-AAAA","surface_id":"SF-1111","created_at":"2026-11-09T02:13:00Z","is_read":true,"title":null,"title_length":11,"subtitle":null,"subtitle_length":7,"body":null,"body_length":32,"redacted_fields":["title","subtitle","body"]}}
    ]
    """#

    static func event(_ name: String) throws -> EventFrame {
        let events = try JSONDecoder().decode([EventFrame].self, from: Data(eventsJSON.utf8))
        return try XCTUnwrap(events.first { $0.name == name })
    }

    /// `notification.created` after the relay filled it from `notification.list`.
    static func filledCreated() throws -> EventFrame {
        var event = try event("notification.created")
        guard case .object(var payload) = event.payload else { throw ShapeError() }
        payload["title"] = .string("Claude Code")
        payload["subtitle"] = .string("agent-lab")
        payload["body"] = .string("Claude is waiting for your input")
        payload["tab_title"] = .string("claude")
        payload["redacted_fields"] = nil
        event.payload = .object(payload)
        return event
    }
}
