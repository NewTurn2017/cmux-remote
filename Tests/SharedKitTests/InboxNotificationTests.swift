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
        XCTAssertEqual(record?.title, "cmux 알림")
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
}
