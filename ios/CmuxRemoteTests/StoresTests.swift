import XCTest
import SharedKit
@testable import CmuxRemote

@MainActor
final class StoresTests: XCTestCase {
    func testWorkspaceRefreshLoadsSurfaces() async {
        let rpc = StubRPCDispatch()
        let store = WorkspaceStore(rpc: rpc)
        await store.refresh()
        XCTAssertEqual(store.workspaces.first?.name, "Demo")
        XCTAssertEqual(store.surfaceCount(for: "w1"), 1)
        XCTAssertEqual(store.connection, .connected)
    }

    func testEndpointPolicyAllowsOnlyTailscaleScopedHosts() {
        XCTAssertTrue(EndpointPolicy.isAllowedRelayHost("mac.tailnet.ts.net"))
        XCTAssertTrue(EndpointPolicy.isAllowedRelayHost("100.115.102.6"))
        XCTAssertFalse(EndpointPolicy.isAllowedRelayHost("example.com"))
        XCTAssertFalse(EndpointPolicy.isAllowedRelayHost("192.168.1.5"))
    }


    func testWorkspaceStoreCreatesSurfaceAndSelectsReturnedSurface() async throws {
        let rpc = StubRPCDispatch()
        let store = WorkspaceStore(rpc: rpc)
        await store.refresh()

        let surface = try await store.createSurface(workspaceId: "w1")

        XCTAssertEqual(surface.id, "s2")
        XCTAssertEqual(store.surfaceCount(for: "w1"), 2)
        let calls = await rpc.calls
        XCTAssertTrue(calls.contains { call in
            guard call.method == "surface.create",
                  case .object(let params) = call.params,
                  case .string("w1")? = params["workspace_id"],
                  case .string("terminal")? = params["type"]
            else { return false }
            return true
        })
    }

    func testWorkspaceStoreClosesSurfaceAndRefreshesList() async throws {
        let rpc = StubRPCDispatch(surfaces: [("s1", "shell"), ("s2", "logs")])
        let store = WorkspaceStore(rpc: rpc)
        await store.refresh()

        try await store.closeSurface(workspaceId: "w1", surfaceId: "s1")

        XCTAssertEqual(store.surfaces(for: "w1").map(\.id), ["s2"])
        let calls = await rpc.calls
        XCTAssertTrue(calls.contains { call in
            guard call.method == "surface.close",
                  case .object(let params) = call.params,
                  case .string("w1")? = params["workspace_id"],
                  case .string("s1")? = params["surface_id"]
            else { return false }
            return true
        })
    }

    func testStoresResetDisconnectState() async {
        let rpc = StubRPCDispatch()
        let workspaceStore = WorkspaceStore(rpc: rpc)
        await workspaceStore.refresh()
        workspaceStore.reset()
        XCTAssertEqual(workspaceStore.workspaces.count, 0)
        XCTAssertEqual(workspaceStore.connection, .disconnected)

        let surfaceStore = SurfaceStore(rpc: rpc)
        await surfaceStore.subscribe(workspaceId: "w1", surfaceId: "s1")
        surfaceStore.reset()
        XCTAssertNil(surfaceStore.subscribed)
        XCTAssertEqual(surfaceStore.grid.rows.count, 24)
    }

    func testSurfaceStoreSendsTextAndKeys() async throws {
        let rpc = StubRPCDispatch()
        let surfaceStore = SurfaceStore(rpc: rpc)

        try await surfaceStore.sendText(workspaceId: "w1", surfaceId: "s1", text: "ls\n")
        try await surfaceStore.sendKey(workspaceId: "w1", surfaceId: "s1", key: .named("c", modifiers: [.ctrl]))

        let calls = await rpc.calls
        XCTAssertEqual(calls.map(\.method), ["surface.send_text", "surface.send_key"])
        XCTAssertEqual(surfaceStore.inputStatus, .sent("Sent ctrl+c"))
        XCTAssertTrue(calls.contains { call in
            guard call.method == "surface.send_text",
                  case .object(let params) = call.params,
                  case .string("ls\n")? = params["text"]
            else { return false }
            return true
        })
        XCTAssertTrue(calls.contains { call in
            guard call.method == "surface.send_key",
                  case .object(let params) = call.params,
                  case .string("ctrl+c")? = params["key"]
            else { return false }
            return true
        })
    }

    func testSurfaceStoreSubmitsCommandAsTextThenEnter() async throws {
        let rpc = StubRPCDispatch()
        let surfaceStore = SurfaceStore(rpc: rpc)

        try await surfaceStore.submitCommand(workspaceId: "w1", surfaceId: "s1", command: "pwd")

        let calls = await rpc.calls
        XCTAssertEqual(calls.suffix(2).map(\.method), ["surface.send_text", "surface.send_key"])
        XCTAssertEqual(surfaceStore.inputStatus, .sent("Sent pwd"))
        XCTAssertTrue(calls.contains { call in
            guard call.method == "surface.send_text",
                  case .object(let params) = call.params,
                  case .string("pwd")? = params["text"]
            else { return false }
            return true
        })
        XCTAssertTrue(calls.contains { call in
            guard call.method == "surface.send_key",
                  case .object(let params) = call.params,
                  case .string("enter")? = params["key"]
            else { return false }
            return true
        })
    }

    func testSurfaceStoreReportsInputDispatchFailure() async {
        let rpc = FailingRPCDispatch()
        let surfaceStore = SurfaceStore(rpc: rpc)

        do {
            try await surfaceStore.sendText(workspaceId: "w1", surfaceId: "s1", text: "ls\n")
            XCTFail("Expected sendText to throw")
        } catch {
            guard case .failed(let message) = surfaceStore.inputStatus else {
                return XCTFail("Expected failed status, got \(surfaceStore.inputStatus)")
            }
            XCTAssertTrue(message.contains("closed") || message.contains("offline"))
        }
    }


    func testNotificationStoreIngestsFullNotificationEvent() {
        let store = NotificationStore()
        let frame = PushFrame.event(EventFrame(
            category: .notification,
            name: "notification.created",
            payload: .object([
                "id": .string("n1"),
                "workspace_id": .string("w1"),
                "surface_id": .string("s1"),
                "title": .string("작업 완료"),
                "subtitle": .string("요술마켓"),
                "body": .string("테스트가 끝났습니다."),
                "ts": .int(42),
                "thread_id": .string("th1"),
            ])
        ))

        store.ingest(frame)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.id, "n1")
        XCTAssertEqual(store.items.first?.workspaceId, "w1")
        XCTAssertEqual(store.items.first?.surfaceId, "s1")
        XCTAssertEqual(store.items.first?.title, "작업 완료")
    }

    func testNotificationStoreKeepsPartialCmuxNotificationEventsVisible() {
        let store = NotificationStore()
        let frame = PushFrame.event(EventFrame(
            category: .notification,
            name: "notification.created",
            payload: .object([
                "id": .string("n-partial"),
                "workspace_id": .string("w1"),
                "message": .string("새 알림이 도착했습니다."),
            ])
        ))

        store.ingest(frame)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.id, "n-partial")
        XCTAssertEqual(store.items.first?.workspaceId, "w1")
        XCTAssertEqual(store.items.first?.title, "cmux 알림")
        XCTAssertEqual(store.items.first?.body, "새 알림이 도착했습니다.")
        XCTAssertEqual(store.items.first?.threadId, "workspace-w1")
    }

    func testNotificationStoreIgnoresNonNotificationEvents() {
        let store = NotificationStore()
        store.ingest(.event(EventFrame(
            category: .workspace,
            name: "workspace.updated",
            payload: .object(["id": .string("w1")])
        )))

        XCTAssertTrue(store.items.isEmpty)
    }

    func testNotificationStoreFiresOnNewOnceForRepeatedId() {
        let store = NotificationStore()
        var fired: [String] = []
        store.onNew = { record in fired.append(record.id) }

        let frame = PushFrame.event(EventFrame(
            category: .notification,
            name: "notification.created",
            payload: .object([
                "id": .string("dup-1"),
                "workspace_id": .string("w1"),
                "title": .string("once"),
                "body": .string("only"),
            ])
        ))

        store.ingest(frame)
        store.ingest(frame)

        XCTAssertEqual(fired, ["dup-1"])
    }

    func testNotificationStoreCapsNewestFirst() {
        let store = NotificationStore()
        for i in 0..<205 {
            store.append(NotificationRecord(id: "n\(i)", workspaceId: "w", surfaceId: nil, title: "t\(i)", subtitle: nil, body: "b", ts: Int64(i), threadId: "th"))
        }
        XCTAssertEqual(store.items.count, 200)
        XCTAssertEqual(store.items.first?.id, "n204")
        XCTAssertEqual(store.items.last?.id, "n5")
    }
}

private actor FailingRPCDispatch: RPCDispatch {
    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        throw RPCClientError.closed
    }
}
