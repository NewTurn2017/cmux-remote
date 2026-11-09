import XCTest
@testable import RelayCore
@testable import SharedKit

final class InboxPushFanoutTests: XCTestCase {
    func testSendsInboxEventToRegisteredDeviceToken() async throws {
        let store = try emptyStore()
        _ = try store.register(deviceId: "d1", loginName: "a", hostname: "iPhone", apnsToken: nil)
        try store.setAPNsToken(deviceId: "d1", token: "token-1", env: "sandbox")
        let sender = RecordingAPNsSender()
        let fanout = InboxPushFanout(
            deviceStore: store,
            sender: sender,
            config: { testAPNsConfig }
        )

        await fanout.deliver(event: EventFrame(
            category: .notification,
            name: "notification.created",
            payload: .object([
                "id": .string("n1"),
                "workspace_id": .string("w1"),
                "surface_id": .string("s1"),
                "title": .string("Codex needs input"),
                "body": .string("terminal SECRET_TOKEN must not be sent by provider"),
            ])
        ))

        let pushes = await sender.recordedPushes()
        XCTAssertEqual(pushes.count, 1)
        XCTAssertEqual(pushes.first?.deviceToken, "token-1")
        XCTAssertEqual(pushes.first?.environment, "sandbox")
        XCTAssertEqual(pushes.first?.notification.workspaceId, "w1")
        XCTAssertEqual(pushes.first?.notification.surfaceId, "s1")
    }

    func testSkipsNonInboxEventsAndEnvMismatches() async throws {
        let store = try emptyStore()
        _ = try store.register(deviceId: "d1", loginName: "a", hostname: "iPhone", apnsToken: nil)
        try store.setAPNsToken(deviceId: "d1", token: "token-1", env: "prod")
        let sender = RecordingAPNsSender()
        let fanout = InboxPushFanout(
            deviceStore: store,
            sender: sender,
            config: { testAPNsConfig }
        )

        await fanout.deliver(event: EventFrame(
            category: .workspace,
            name: "workspace.updated",
            payload: .object(["workspace_id": .string("w1")])
        ))
        await fanout.deliver(event: EventFrame(
            category: .notification,
            name: "notification.created",
            payload: .object(["workspace_id": .string("w1"), "title": .string("hi")])
        ))

        let pushes = await sender.recordedPushes()
        XCTAssertTrue(pushes.isEmpty)
    }

    func testInternalNotificationEventsAreNeverPushed() async throws {
        let store = try emptyStore()
        _ = try store.register(deviceId: "d1", loginName: "a", hostname: "iPhone", apnsToken: nil)
        try store.setAPNsToken(deviceId: "d1", token: "token-1", env: "sandbox")
        let sender = RecordingAPNsSender()
        let fanout = InboxPushFanout(deviceStore: store, sender: sender, config: { testAPNsConfig })
        let statePayload: JSONValue = .object([
            "notification_id": .string("N-0001"),
            "workspace_id": .string("WS-AAAA"),
            "title": .null,
            "redacted_fields": .array([.string("title"), .string("subtitle"), .string("body")]),
        ])

        for name in ["notification.requested", "notification.read", "notification.removed", "notification.clear_requested"] {
            await fanout.deliver(event: EventFrame(category: .notification, name: name, payload: statePayload))
        }

        let pushes = await sender.recordedPushes()
        XCTAssertTrue(pushes.isEmpty)
    }

    func testFilledCreatedNotificationPushesItsContent() async throws {
        let store = try emptyStore()
        _ = try store.register(deviceId: "d1", loginName: "a", hostname: "iPhone", apnsToken: nil)
        try store.setAPNsToken(deviceId: "d1", token: "token-1", env: "sandbox")
        let sender = RecordingAPNsSender()
        let fanout = InboxPushFanout(deviceStore: store, sender: sender, config: { testAPNsConfig })

        await fanout.deliver(event: EventFrame(
            category: .notification,
            name: "notification.created",
            payload: .object([
                "notification_id": .string("N-0001"),
                "workspace_id": .string("WS-AAAA"),
                "surface_id": .string("SF-1111"),
                "title": .string("Claude Code"),
                "subtitle": .string("agent-lab"),
                "body": .string("Claude is waiting for your input"),
                "tab_title": .string("claude"),
            ])
        ))

        let pushes = await sender.recordedPushes()
        XCTAssertEqual(pushes.count, 1)
        let notification = try XCTUnwrap(pushes.first?.notification)
        XCTAssertEqual(notification.id, "N-0001")
        XCTAssertEqual(APNsProviderClient.alert(for: notification), [
            "title": "Claude Code",
            "subtitle": "agent-lab",
            "body": "Claude is waiting for your input",
        ])
    }

    func testInvalidTokenResponseClearsStoredToken() async throws {
        let store = try emptyStore()
        _ = try store.register(deviceId: "d1", loginName: "a", hostname: "iPhone", apnsToken: nil)
        try store.setAPNsToken(deviceId: "d1", token: "token-1", env: "sandbox")
        let sender = RecordingAPNsSender(result: .invalidToken(reason: "Unregistered", apnsId: "apns-1"))
        let fanout = InboxPushFanout(
            deviceStore: store,
            sender: sender,
            config: { testAPNsConfig }
        )

        await fanout.deliver(event: EventFrame(
            category: .notification,
            name: "notification.created",
            payload: .object(["workspace_id": .string("w1"), "title": .string("hi")])
        ))

        XCTAssertNil(store.lookup(deviceId: "d1")?.apnsToken)
        XCTAssertNil(store.lookup(deviceId: "d1")?.apnsEnv)
    }

    private func emptyStore() throws -> DeviceStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("InboxPushFanoutTests-\(UUID()).json")
        return try DeviceStore(url: path)
    }
}

private let testAPNsConfig = RelayConfig.APNs(
    keyPath: "/dev/null",
    keyId: "K",
    teamId: "T",
    topic: "com.genie.CmuxRemote",
    env: "sandbox"
)

private actor RecordingAPNsSender: APNsSending {
    private(set) var pushes: [APNsPushAlert] = []
    let result: APNsSendResult

    init(result: APNsSendResult = .delivered(apnsId: "ok")) {
        self.result = result
    }

    func send(_ push: APNsPushAlert) async throws -> APNsSendResult {
        pushes.append(push)
        return result
    }

    func recordedPushes() -> [APNsPushAlert] {
        pushes
    }
}
