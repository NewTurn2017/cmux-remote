import XCTest
import SharedKit
@testable import CmuxRemote

@MainActor
final class NotificationStoreTests: XCTestCase {
    private func makeStore() -> (NotificationStore, () -> [String]) {
        let store = NotificationStore()
        var bannerIds: [String] = []
        store.onNew = { bannerIds.append($0.id) }
        return (store, { bannerIds })
    }

    func testRedactedSequenceFromOlderRelayKeepsOneCardAndAppliesState() throws {
        let (store, banners) = makeStore()

        store.ingest(.event(try NotificationEventFixture.event("notification.requested")))
        XCTAssertTrue(store.items.isEmpty)

        store.ingest(.event(try NotificationEventFixture.event("notification.created")))
        XCTAssertEqual(store.items.map(\.id), ["N-0001"])
        XCTAssertEqual(store.items.first?.title, InboxNotification.fallbackTitle)
        XCTAssertEqual(store.items.first?.body, "")
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(banners(), ["N-0001"])

        store.ingest(.event(try NotificationEventFixture.event("notification.read")))
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertFalse(store.isUnread("N-0001"))

        store.ingest(.event(try NotificationEventFixture.event("notification.removed")))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(banners(), ["N-0001"])
    }

    func testFilledCreatedShowsContentAndRaisesOneBannerPerId() throws {
        let (store, banners) = makeStore()
        let filled = try NotificationEventFixture.filledCreated()

        store.ingest(.event(filled))
        store.ingest(.event(filled))

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.title, "Claude Code")
        XCTAssertEqual(store.items.first?.subtitle, "agent-lab")
        XCTAssertEqual(store.items.first?.body, "Claude is waiting for your input")
        XCTAssertEqual(banners(), ["N-0001"])
    }

    func testRepeatedCreatedUpdatesTheCardInPlace() throws {
        let (store, banners) = makeStore()
        store.ingest(.event(try NotificationEventFixture.event("notification.created")))

        store.ingest(.event(try NotificationEventFixture.filledCreated()))

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.title, "Claude Code")
        XCTAssertEqual(banners(), ["N-0001"])
    }

    func testReplacedNotificationsLeaveTheInbox() throws {
        let (store, _) = makeStore()
        store.ingest(.event(try NotificationEventFixture.created(id: "N-0000", replacing: [])))

        store.ingest(.event(try NotificationEventFixture.event("notification.created")))

        XCTAssertEqual(store.items.map(\.id), ["N-0001"])
        XCTAssertEqual(store.unreadCount, 1)
    }

    func testCreatedThatIsAlreadyReadStaysQuiet() throws {
        let (store, banners) = makeStore()
        var event = try NotificationEventFixture.event("notification.created")
        guard case .object(var payload) = event.payload else { return XCTFail("object payload") }
        payload["is_read"] = .bool(true)
        event.payload = .object(payload)

        store.ingest(.event(event))

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertTrue(banners().isEmpty)
    }

    func testDisabledLocalNotificationsSuppressCreatedBanner() throws {
        let (store, banners) = makeStore()
        store.localNotificationsEnabled = false

        store.ingest(.event(try NotificationEventFixture.filledCreated()))

        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(banners().isEmpty)
    }

    func testReadBeforeCreatedDoesNotHideTheLaterCard() throws {
        let (store, _) = makeStore()

        store.ingest(.event(try NotificationEventFixture.event("notification.read")))
        store.ingest(.event(try NotificationEventFixture.event("notification.created")))

        XCTAssertEqual(store.unreadCount, 1)
    }

    func testClearRequestedAndOtherNotificationEventsAreIgnored() {
        let (store, _) = makeStore()
        for name in ["notification.clear_requested", "notification.updated"] {
            store.ingest(.event(EventFrame(
                category: .notification,
                name: name,
                payload: .object(["workspace_id": .string("WS-AAAA"), "title": .string("Claude Code")])
            )))
        }

        XCTAssertTrue(store.items.isEmpty)
    }

    func testAgentNeedsInputEventsKeepTheirAppendBehavior() {
        let (store, banners) = makeStore()
        let frame = PushFrame.event(EventFrame(
            category: .hook,
            name: "codex.permission_prompt",
            payload: .object([
                "workspace_id": .string("w1"),
                "surface_id": .string("s1"),
                "source": .string("Codex"),
                "message": .string("approval required"),
            ])
        ))

        store.ingest(frame)
        store.ingest(frame)

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(banners().count, 1)
        XCTAssertEqual(store.items.first?.title, "Codex needs input")
    }
}

/// Event payloads copied from the lane fixture `cmux-notification-events.json` (sha256
/// c8188d9cc0e8d509; key shape measured on cmux build 113, values invented).
enum NotificationEventFixture {
    struct ShapeError: Error {}

    static let eventsJSON = #"""
    [
     {"category":"notification","name":"notification.requested",
      "payload":{"method":"notification.create_for_target","params":{"title":null,"title_length":8,"subtitle":null,"subtitle_length":8,"body":null,"body_length":8,"redacted_fields":["title","subtitle","body"],"effects":{"desktop":false},"surface_id":"SF-1111","workspace_id":"WS-AAAA"},"result":{"id":"N-0001","surface_id":"SF-1111","surface_ref":"surface:1","window_id":"WIN-1","window_ref":"window:1","workspace_id":"WS-AAAA","workspace_ref":"workspace:1"}}},
     {"category":"notification","name":"notification.created",
      "payload":{"notification_id":"N-0001","workspace_id":"WS-AAAA","surface_id":"SF-1111","created_at":"2026-11-09T02:13:00Z","is_read":false,"delivery":"store","replaced_notification_ids":["N-0000"],"title":null,"title_length":11,"subtitle":null,"subtitle_length":7,"body":null,"body_length":32,"redacted_fields":["title","subtitle","body"]}},
     {"category":"notification","name":"notification.read",
      "payload":{"notification_id":"N-0001","workspace_id":"WS-AAAA","surface_id":"SF-1111","created_at":"2026-11-09T02:13:00Z","is_read":true,"title":null,"title_length":11,"subtitle":null,"subtitle_length":7,"body":null,"body_length":32,"redacted_fields":["title","subtitle","body"]}},
     {"category":"notification","name":"notification.removed",
      "payload":{"notification_id":"N-0001","workspace_id":"WS-AAAA","surface_id":"SF-1111","created_at":"2026-11-09T02:13:00Z","is_read":true,"title":null,"title_length":11,"subtitle":null,"subtitle_length":7,"body":null,"body_length":32,"redacted_fields":["title","subtitle","body"]}}
    ]
    """#

    static func event(_ name: String) throws -> EventFrame {
        let events = try JSONDecoder().decode([EventFrame].self, from: Data(eventsJSON.utf8))
        return try XCTUnwrap(events.first { $0.name == name })
    }

    static func created(id: String, replacing: [String]) throws -> EventFrame {
        var event = try event("notification.created")
        guard case .object(var payload) = event.payload else { throw ShapeError() }
        payload["notification_id"] = .string(id)
        payload["replaced_notification_ids"] = .array(replacing.map(JSONValue.string))
        event.payload = .object(payload)
        return event
    }

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
