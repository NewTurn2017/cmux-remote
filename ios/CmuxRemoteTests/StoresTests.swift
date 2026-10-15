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


    func testWorkspaceRefreshEmitsClaudeCodeNeedsInputAlertFromWorkspaceListStatus() async {
        let rpc = StubRPCDispatch(
            workspaces: [("w1", "말겨봐")],
            workspaceExtras: [
                "w1": [
                    "agent": .string("Claude Code"),
                    "status": .string("Claude is waiting for your input"),
                    "summary": .string("Claude needs your permission"),
                    "active_surface_id": .string("s1"),
                ],
            ]
        )
        let store = WorkspaceStore(rpc: rpc)
        var alerts: [NotificationRecord] = []
        store.onWorkspaceAlert = { alerts.append($0) }

        await store.refresh()

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.workspaceId, "w1")
        XCTAssertEqual(alerts.first?.surfaceId, "s1")
        XCTAssertEqual(alerts.first?.title, "Claude Code needs input")
        XCTAssertEqual(alerts.first?.body, "Claude is waiting for your input")
        XCTAssertTrue(alerts.first?.id.contains("workspace-alert") ?? false)
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


    func testWorkspaceStoreCreatesWorkspaceWithRequestedTitle() async throws {
        let rpc = StubRPCDispatch(workspaces: [("w1", "Demo")])
        let store = WorkspaceStore(rpc: rpc)
        await store.refresh()

        try await store.create(name: "요술마켓")

        XCTAssertEqual(store.workspaces.map(\.name), ["Demo", "요술마켓"])
        let calls = await rpc.calls
        XCTAssertTrue(calls.contains { call in
            guard call.method == "workspace.create",
                  case .object(let params) = call.params,
                  case .string("요술마켓")? = params["title"]
            else { return false }
            return true
        })
    }

    func testWorkspaceStoreRenamesWorkspaceWithTitleParam() async throws {
        let rpc = StubRPCDispatch(workspaces: [("w1", "Demo"), ("w2", "Logs")])
        let store = WorkspaceStore(rpc: rpc)
        await store.refresh()

        try await store.rename(workspaceId: "w2", title: "빌드 로그")

        XCTAssertEqual(store.workspaces.map(\.name), ["Demo", "빌드 로그"])
        let calls = await rpc.calls
        XCTAssertTrue(calls.contains { call in
            guard call.method == "workspace.rename",
                  case .object(let params) = call.params,
                  case .string("w2")? = params["workspace_id"],
                  case .string("빌드 로그")? = params["title"]
            else { return false }
            return true
        })
    }

    func testWorkspaceStoreClosesWorkspaceAndRefreshesSelection() async throws {
        let rpc = StubRPCDispatch(workspaces: [("w1", "Demo"), ("w2", "Logs")])
        let store = WorkspaceStore(rpc: rpc)
        await store.refresh()
        store.selectedId = "w1"

        try await store.close(workspaceId: "w1")

        XCTAssertEqual(store.workspaces.map(\.id), ["w2"])
        XCTAssertEqual(store.selectedId, "w2")
        XCTAssertNil(store.surfacesByWorkspaceId["w1"])
        let calls = await rpc.calls
        XCTAssertTrue(calls.contains { call in
            guard call.method == "workspace.close",
                  case .object(let params) = call.params,
                  case .string("w1")? = params["workspace_id"]
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

    func testSurfaceSubscribeRequestsBoundedTerminalHistory() async {
        let rpc = StubRPCDispatch()
        let surfaceStore = SurfaceStore(rpc: rpc)

        await surfaceStore.subscribe(workspaceId: "w1", surfaceId: "s1")

        let calls = await rpc.calls
        XCTAssertTrue(calls.contains { call in
            guard call.method == "surface.subscribe",
                  case .object(let params) = call.params,
                  case .int(let lines)? = params["lines"]
            else { return false }
            return lines == Int64(SurfaceStore.defaultSubscriptionLines)
        })
        XCTAssertTrue(calls.contains { call in
            guard call.method == "surface.read_text",
                  case .object(let params) = call.params,
                  case .int(let lines)? = params["lines"]
            else { return false }
            return lines == Int64(SurfaceStore.defaultSubscriptionLines)
        })
    }

    func testSurfaceResubscribeRequestsBoundedTerminalHistory() async {
        let rpc = StubRPCDispatch()
        let surfaceStore = SurfaceStore(rpc: rpc)
        surfaceStore.subscribedWorkspaceId = "w1"
        surfaceStore.subscribed = "s1"

        await surfaceStore.resubscribe()

        let calls = await rpc.calls
        XCTAssertTrue(calls.contains { call in
            guard call.method == "surface.subscribe",
                  case .object(let params) = call.params,
                  case .int(let lines)? = params["lines"]
            else { return false }
            return lines == Int64(SurfaceStore.defaultSubscriptionLines)
        })
        XCTAssertTrue(calls.contains { call in
            guard call.method == "surface.read_text",
                  case .object(let params) = call.params,
                  case .int(let lines)? = params["lines"]
            else { return false }
            return lines == Int64(SurfaceStore.defaultSubscriptionLines)
        })
    }

    func testRejectedSubscribeDoesNotPresentPreviousSurfaceAsNewSelection() async {
        let rpc = SubscribeRejectingRPCDispatch(rejectedSurfaceIds: ["s2"])
        let surfaceStore = SurfaceStore(rpc: rpc)
        await surfaceStore.subscribe(workspaceId: "w1", surfaceId: "s1")
        surfaceStore.ingest(.screenFull(Self.fullFrame(surfaceId: "s1", rev: 1, text: "WORKSPACE A")))
        XCTAssertEqual(surfaceStore.grid.rawRows.first, "WORKSPACE A")

        await surfaceStore.subscribe(workspaceId: "w2", surfaceId: "s2")

        XCTAssertFalse(surfaceStore.grid.rawRows.contains("WORKSPACE A"))
        XCTAssertNotNil(surfaceStore.subscriptionError)
        XCTAssertTrue(surfaceStore.subscriptionError?.contains("surface_subscription_failed") == true)
        let reads = await rpc.calls.filter { $0.method == "surface.read_text" || $0.method == "surface.focus" }
        XCTAssertTrue(reads.allSatisfy { call in
            guard case .object(let params) = call.params else { return false }
            return params["surface_id"] == .string("s1")
        })

        surfaceStore.ingest(.screenFull(Self.fullFrame(surfaceId: "s1", rev: 2, text: "LATE A")))
        XCTAssertFalse(surfaceStore.grid.rawRows.contains("LATE A"))
    }

    func testSuccessfulSurfaceSwitchClearsPreviousScreenUntilNewFrame() async {
        let rpc = SubscribeRejectingRPCDispatch(rejectedSurfaceIds: [])
        let surfaceStore = SurfaceStore(rpc: rpc)
        await surfaceStore.subscribe(workspaceId: "w1", surfaceId: "s1")
        surfaceStore.ingest(.screenFull(Self.fullFrame(surfaceId: "s1", rev: 1, text: "WORKSPACE A")))

        await surfaceStore.subscribe(workspaceId: "w2", surfaceId: "s2")

        XCTAssertFalse(surfaceStore.grid.rawRows.contains("WORKSPACE A"))
        XCTAssertNil(surfaceStore.subscriptionError)
        surfaceStore.ingest(.screenFull(Self.fullFrame(surfaceId: "s2", rev: 1, text: "WORKSPACE B")))
        XCTAssertEqual(surfaceStore.grid.rawRows.first, "WORKSPACE B")
    }

    func testReadFromPreviousSelectionDoesNotLandAfterSwitch() async {
        let rpc = SubscribeRejectingRPCDispatch(rejectedSurfaceIds: ["s2"], gatedRead: (surfaceId: "s1", text: "OLD A"))
        let surfaceStore = SurfaceStore(rpc: rpc)
        let first = Task { await surfaceStore.subscribe(workspaceId: "w1", surfaceId: "s1") }
        while await !rpc.gatedReadStarted { await Task.yield() }

        await surfaceStore.subscribe(workspaceId: "w2", surfaceId: "s2")
        await rpc.releaseGatedRead()
        await first.value

        XCTAssertEqual(surfaceStore.subscribed, "s2")
        XCTAssertFalse(surfaceStore.grid.rawRows.contains("OLD A"))
    }

    func testFramesForRejectedSubscriptionAreDropped() async {
        let rpc = SubscribeRejectingRPCDispatch(rejectedSurfaceIds: ["s2"])
        let surfaceStore = SurfaceStore(rpc: rpc)
        await surfaceStore.subscribe(workspaceId: "w2", surfaceId: "s2")
        XCTAssertNotNil(surfaceStore.subscriptionError)

        surfaceStore.ingest(.screenFull(Self.fullFrame(surfaceId: "s2", rev: 1, text: "BUFFERED B")))

        XCTAssertFalse(surfaceStore.grid.rawRows.contains("BUFFERED B"))
    }

    func testResubscribeSuccessClearsSubscriptionError() async {
        let rpc = SubscribeRejectingRPCDispatch(rejectedSurfaceIds: ["s2"])
        let surfaceStore = SurfaceStore(rpc: rpc)
        await surfaceStore.subscribe(workspaceId: "w2", surfaceId: "s2")
        XCTAssertNotNil(surfaceStore.subscriptionError)

        await rpc.accept("s2")
        await surfaceStore.resubscribe()

        XCTAssertNil(surfaceStore.subscriptionError)
        XCTAssertEqual(surfaceStore.subscribed, "s2")
    }

    func testOlderSwitchDoesNotOverwriteNewerSelection() async {
        let rpc = UnsubscribeGatingRPCDispatch()
        let surfaceStore = SurfaceStore(rpc: rpc)
        await surfaceStore.subscribe(workspaceId: "w1", surfaceId: "s1")
        await rpc.holdNextUnsubscribe()
        let toS2 = Task { await surfaceStore.subscribe(workspaceId: "w2", surfaceId: "s2") }
        while await !rpc.heldUnsubscribeStarted { await Task.yield() }

        await surfaceStore.subscribe(workspaceId: "w3", surfaceId: "s3")
        await rpc.releaseHeldUnsubscribe()
        await toS2.value

        XCTAssertEqual(surfaceStore.subscribed, "s3")
        XCTAssertEqual(surfaceStore.subscribedWorkspaceId, "w3")
        let subscribes = await rpc.calls.filter { $0.method == "surface.subscribe" }
        XCTAssertFalse(subscribes.contains { call in
            guard case .object(let params) = call.params else { return false }
            return params["surface_id"] == .string("s2")
        })
    }

    func testRateLimitedSurfaceListKeepsKnownSurfaces() async {
        let rpc = RateLimitingRPCDispatch()
        let store = WorkspaceStore(rpc: rpc)
        await store.refresh()
        XCTAssertEqual(store.surfaces(for: "w1").map(\.id), ["s1"])

        await rpc.setLimitSurfaceList(true)
        await store.refresh()

        XCTAssertEqual(store.surfaces(for: "w1").map(\.id), ["s1"])
        XCTAssertEqual(store.connection, .connected)
    }

    func testRefreshOverLiveConnectionDoesNotShowConnecting() async {
        let rpc = RateLimitingRPCDispatch()
        let store = WorkspaceStore(rpc: rpc)
        await store.refresh()
        XCTAssertEqual(store.connection, .connected)

        await rpc.holdNextWorkspaceList()
        let reload = Task { await store.refresh() }
        while await !rpc.heldWorkspaceListStarted { await Task.yield() }
        XCTAssertEqual(store.connection, .connected)
        await rpc.releaseWorkspaceList()
        await reload.value
        XCTAssertEqual(store.connection, .connected)
    }

    func testUnsubscribeClearsScreenAndDropsReleasedSurfaceFrames() async {
        let surfaceStore = SurfaceStore(rpc: StubRPCDispatch())
        await surfaceStore.subscribe(workspaceId: "w1", surfaceId: "s1")
        surfaceStore.ingest(.screenFull(Self.fullFrame(surfaceId: "s1", rev: 1, text: "WORKSPACE A")))

        await surfaceStore.unsubscribe(surfaceId: "s1")

        XCTAssertNil(surfaceStore.subscribed)
        XCTAssertFalse(surfaceStore.grid.rawRows.contains("WORKSPACE A"))
        surfaceStore.ingest(.screenFull(Self.fullFrame(surfaceId: "s1", rev: 2, text: "LATE A")))
        XCTAssertFalse(surfaceStore.grid.rawRows.contains("LATE A"))
    }

    private static func fullFrame(surfaceId: String, rev: Int, text: String) -> ScreenFull {
        ScreenFull(
            surfaceId: surfaceId,
            rev: rev,
            rows: [text, ""],
            cols: 12,
            rowsCount: 2,
            cursor: CursorPos(x: 0, y: 0)
        )
    }

    func testSurfaceStoreSameGeometryFullRefreshPreservesSelectionEpoch() {
        let surfaceStore = SurfaceStore(rpc: StubRPCDispatch())
        surfaceStore.ingest(.screenFull(ScreenFull(
            surfaceId: "s1",
            rev: 1,
            rows: ["old", ""],
            cols: 12,
            rowsCount: 2,
            cursor: CursorPos(x: 0, y: 0)
        )))
        let selectionEpochID = surfaceStore.grid.selectionEpochID

        surfaceStore.ingest(.screenFull(ScreenFull(
            surfaceId: "s1",
            rev: 2,
            rows: ["new", "content"],
            cols: 12,
            rowsCount: 2,
            cursor: CursorPos(x: 3, y: 1)
        )))

        XCTAssertEqual(surfaceStore.grid.selectionEpochID, selectionEpochID)
        XCTAssertEqual(surfaceStore.grid.rawRows, ["new", "content"])
        XCTAssertEqual(surfaceStore.grid.cursor, CursorPos(x: 3, y: 1))
        XCTAssertEqual(surfaceStore.rev, 2)
    }

    func testSurfaceStoreGeometryChangingFullRefreshAdvancesSelectionEpoch() {
        let surfaceStore = SurfaceStore(rpc: StubRPCDispatch())
        surfaceStore.ingest(.screenFull(ScreenFull(
            surfaceId: "s1",
            rev: 1,
            rows: ["old", ""],
            cols: 12,
            rowsCount: 2,
            cursor: CursorPos(x: 0, y: 0)
        )))
        let selectionEpochID = surfaceStore.grid.selectionEpochID

        surfaceStore.ingest(.screenFull(ScreenFull(
            surfaceId: "s1",
            rev: 2,
            rows: ["new", "content", "row"],
            cols: 16,
            rowsCount: 3,
            cursor: CursorPos(x: 3, y: 2)
        )))

        XCTAssertNotEqual(surfaceStore.grid.selectionEpochID, selectionEpochID)
    }

    func testSurfaceStoreSendsTextAndKeys() async throws {
        let rpc = StubRPCDispatch()
        let surfaceStore = SurfaceStore(rpc: rpc)

        try await surfaceStore.sendText(workspaceId: "w1", surfaceId: "s1", text: "ls\n")
        try await surfaceStore.sendKey(workspaceId: "w1", surfaceId: "s1", key: .named("c", modifiers: [.ctrl]))

        let calls = await rpc.calls
        XCTAssertEqual(calls.map(\.method), ["surface.send_text", "surface.focus", "surface.send_key"])
        XCTAssertEqual(surfaceStore.inputStatus, .sent("Sent ctrl+c"))
        XCTAssertTrue(calls.contains { call in
            guard call.method == "surface.send_text",
                  case .object(let params) = call.params,
                  case .string("ls\n")? = params["text"]
            else { return false }
            return true
        })
        XCTAssertTrue(calls.contains { call in
            guard call.method == "surface.focus",
                  case .object(let params) = call.params,
                  case .string("w1")? = params["workspace_id"],
                  case .string("s1")? = params["surface_id"]
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

    func testSurfaceStoreSubmitsMultilineCommandAsSingleTextThenEnter() async throws {
        let rpc = StubRPCDispatch()
        let surfaceStore = SurfaceStore(rpc: rpc)
        let command = "alpha\nbeta  gamma\r\ndelta\u{0085}epsilon\u{2028}zeta\u{2029}eta"

        try await surfaceStore.submitCommand(workspaceId: "w1", surfaceId: "s1", command: command)

        let calls = await rpc.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map(\.method), ["surface.send_text", "surface.send_key"])
        guard calls.count == 2,
              case .object(let textParams) = calls[0].params,
              case .string(let text) = textParams["text"],
              case .object(let keyParams) = calls[1].params,
              case .string("enter")? = keyParams["key"]
        else {
            return XCTFail("Expected one send_text call followed by one enter")
        }
        XCTAssertEqual(text, "alpha beta  gamma delta epsilon zeta eta")
    }

    func testSurfaceStoreUploadsFileAndReportsPath() async throws {
        let rpc = StubRPCDispatch()
        let surfaceStore = SurfaceStore(rpc: rpc)

        let payload = try await surfaceStore.uploadFile(
            data: Data([0x01, 0x02, 0x03]),
            filename: "photo.jpg",
            mimeType: "image/jpeg"
        )

        XCTAssertEqual(payload.path, "/Users/demo/Downloads/cmux-remote/photo.jpg")
        XCTAssertEqual(surfaceStore.inputStatus, .sent("Attached photo.jpg"))
        let calls = await rpc.calls
        XCTAssertTrue(calls.contains { call in
            guard call.method == "file.upload",
                  case .object(let params) = call.params,
                  case .string("photo.jpg")? = params["filename"],
                  case .string("image/jpeg")? = params["mime_type"],
                  case .string(Data([0x01, 0x02, 0x03]).base64EncodedString())? = params["data_base64"]
            else { return false }
            return true
        })
    }

    func testHostStatusStoreRefreshesBattery() async {
        let rpc = StubRPCDispatch()
        let store = HostStatusStore(rpc: rpc)

        await store.refreshBattery()

        XCTAssertEqual(store.battery.percent, 88)
        XCTAssertEqual(store.battery.displayText, "88% ↯")
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
        XCTAssertEqual(store.items.first?.title, "cmux notification")
        XCTAssertEqual(store.items.first?.body, "새 알림이 도착했습니다.")
        XCTAssertEqual(store.items.first?.threadId, "workspace-w1")
    }

    func testNotificationStoreStoresGenericNotificationCreatedWithoutOnNew() {
        let store = NotificationStore()
        var observed: [NotificationRecord] = []
        store.onNew = { record in observed.append(record) }
        let frame = PushFrame.event(EventFrame(
            category: .notification,
            name: "notification.created",
            payload: .object([
                "id": .string("generic-1"),
                "workspace_id": .string("w1"),
                "title": .string("Build finished"),
                "body": .string("Generic notification"),
            ])
        ))

        store.ingest(frame)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(observed.count, 0)
    }

    func testNotificationStoreSuppressesLocalCallbackWhenDisabled() {
        let store = NotificationStore()
        store.localNotificationsEnabled = false
        var observed: [NotificationRecord] = []
        store.onNew = { record in observed.append(record) }
        let frame = PushFrame.event(EventFrame(
            category: .surface,
            name: "claude.needs_input",
            payload: .object([
                "id": .string("need-disabled"),
                "workspace_id": .string("w1"),
                "surface_id": .string("s1"),
                "title": .string("Claude Code"),
                "body": .string("needs input"),
            ])
        ))

        store.ingest(frame)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(observed.count, 0)
    }

    func testNotificationStoreFiresLocalCallbackForNeedsInputWhenEnabled() {
        let store = NotificationStore()
        var observed: [NotificationRecord] = []
        store.onNew = { record in observed.append(record) }
        let frame = PushFrame.event(EventFrame(
            category: .surface,
            name: "claude.needs_input",
            payload: .object([
                "id": .string("need-enabled"),
                "workspace_id": .string("w1"),
                "surface_id": .string("s1"),
                "title": .string("Claude Code"),
                "body": .string("needs input"),
            ])
        ))

        store.ingest(frame)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(observed.map(\.id), ["need-enabled"])
    }

    func testNotificationStoreMarkAllReadClearsUnreadCounts() {
        let store = NotificationStore()
        store.append(NotificationRecord(id: "n1", workspaceId: "w1", surfaceId: nil, title: "t1", subtitle: nil, body: "b1", ts: 1, threadId: "th1"))
        store.append(NotificationRecord(id: "n2", workspaceId: "w2", surfaceId: nil, title: "t2", subtitle: nil, body: "b2", ts: 2, threadId: "th2"))

        XCTAssertEqual(store.unreadCount, 2)

        store.markAllRead()

        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertTrue(store.unreadByWorkspace.isEmpty)
    }

    func testNotificationStoreDefaultAppendIsInboxOnly() {
        let store = NotificationStore()
        var observed: [NotificationRecord] = []
        store.onNew = { record in observed.append(record) }

        store.append(NotificationRecord(id: "demo-1", workspaceId: "w1", surfaceId: nil, title: "demo", subtitle: nil, body: "inbox only", ts: 1, threadId: "th1"))

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertTrue(observed.isEmpty)
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

    func testNotificationStoreIngestsClaudeNeedsInputEvent() {
        let store = NotificationStore()
        let frame = PushFrame.event(EventFrame(
            category: .surface,
            name: "claude.needs_input",
            payload: .object([
                "workspace_id": .string("w1"),
                "surface_id": .string("s1"),
                "title": .string("Claude Code"),
                "body": .string("needs input"),
                "id": .string("need-1"),
            ])
        ))

        store.ingest(frame)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.id, "need-1")
        XCTAssertEqual(store.items.first?.workspaceId, "w1")
        XCTAssertEqual(store.items.first?.surfaceId, "s1")
        XCTAssertEqual(store.items.first?.title, "Claude Code")
        XCTAssertEqual(store.items.first?.body, "needs input")
    }

    func testNotificationStoreDedupesNeedsInputWithoutExplicitId() {
        let store = NotificationStore()
        var fired: [String] = []
        store.onNew = { record in fired.append(record.id) }
        let frame = PushFrame.event(EventFrame(
            category: .unknown,
            name: "surface.needs-input",
            payload: .object([
                "workspaceId": .string("w1"),
                "surfaceId": .string("s1"),
                "source": .string("Claude Code"),
                "status": .string("needs input"),
            ])
        ))

        store.ingest(frame)
        store.ingest(frame)

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(store.items.first?.id, fired.first)
        XCTAssertEqual(store.items.first?.title, "Claude Code needs input")
        XCTAssertEqual(store.items.first?.body, "needs input")
    }

    func testNotificationStoreIngestsNestedClaudeNeedsAttentionEvent() {
        let store = NotificationStore()
        let frame = PushFrame.event(EventFrame(
            category: .unknown,
            name: "notification",
            payload: .object([
                "workspace": .string("w2"),
                "surface": .string("s2"),
                "details": .object([
                    "message": .string("Claude Code needs your attention"),
                ]),
            ])
        ))

        store.ingest(frame)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.workspaceId, "w2")
        XCTAssertEqual(store.items.first?.surfaceId, "s2")
        XCTAssertEqual(store.items.first?.title, "Claude Code needs input")
        XCTAssertEqual(store.items.first?.body, "Claude Code needs your attention")
    }

    func testNotificationStoreIngestsCodexHookPermissionPromptEvent() {
        let store = NotificationStore()
        let frame = PushFrame.event(EventFrame(
            category: .hook,
            name: "codex.permission_prompt",
            payload: .object([
                "workspace_id": .string("w3"),
                "surface_id": .string("s3"),
                "source": .string("Codex"),
                "message": .string("approval required"),
            ])
        ))

        store.ingest(frame)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.workspaceId, "w3")
        XCTAssertEqual(store.items.first?.surfaceId, "s3")
        XCTAssertEqual(store.items.first?.title, "Codex needs input")
        XCTAssertEqual(store.items.first?.body, "approval required")
    }

    func testNotificationStoreDoesNotAlarmGenericApprovalNoise() {
        let store = NotificationStore()
        let frame = PushFrame.event(EventFrame(
            category: .workspace,
            name: "workspace.updated",
            payload: .object([
                "workspace_id": .string("w4"),
                "source": .string("billing"),
                "message": .string("approval required"),
            ])
        ))

        store.ingest(frame)

        XCTAssertTrue(store.items.isEmpty)
    }

    func testNotificationStoreLabelsUnknownHookNeedsInputAsCmuxHook() {
        let store = NotificationStore()
        let frame = PushFrame.event(EventFrame(
            category: .hook,
            name: "surface.needs-input",
            payload: .object([
                "workspace_id": .string("w5"),
                "message": .string("needs input"),
            ])
        ))

        store.ingest(frame)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.title, "cmux hook needs input")
        XCTAssertEqual(store.items.first?.body, "needs input")
    }

    func testNotificationStoreFiresOnNewOnceForRepeatedNeedsInputId() {
        let store = NotificationStore()
        var fired: [String] = []
        store.onNew = { record in fired.append(record.id) }

        let frame = PushFrame.event(EventFrame(
            category: .surface,
            name: "surface.needs-input",
            payload: .object([
                "id": .string("dup-1"),
                "workspace_id": .string("w1"),
                "source": .string("Claude Code"),
                "body": .string("needs input"),
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

    func testNotificationStoreUnreadCountDropsWhenWorkspaceSeen() {
        let store = NotificationStore()
        store.append(NotificationRecord(id: "n1", workspaceId: "w1", surfaceId: nil, title: "t1", subtitle: nil, body: "b1", ts: 1, threadId: "th1"))
        store.append(NotificationRecord(id: "n2", workspaceId: "w2", surfaceId: nil, title: "t2", subtitle: nil, body: "b2", ts: 2, threadId: "th2"))

        XCTAssertEqual(store.unreadCount, 2)

        store.markWorkspaceSeen("w1")

        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertNil(store.unreadByWorkspace["w1"])
        XCTAssertEqual(store.unreadByWorkspace["w2"], 1)
    }
}

private actor FailingRPCDispatch: RPCDispatch {
    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        throw RPCClientError.closed
    }
}

private actor SubscribeRejectingRPCDispatch: RPCDispatch {
    private(set) var calls: [(method: String, params: JSONValue)] = []
    private var rejectedSurfaceIds: Set<String>
    private let gatedRead: (surfaceId: String, text: String)?
    private(set) var gatedReadStarted = false
    private var gatedReadReleased = false

    init(rejectedSurfaceIds: Set<String>, gatedRead: (surfaceId: String, text: String)? = nil) {
        self.rejectedSurfaceIds = rejectedSurfaceIds
        self.gatedRead = gatedRead
    }

    func releaseGatedRead() {
        gatedReadReleased = true
    }

    func accept(_ surfaceId: String) {
        rejectedSurfaceIds.remove(surfaceId)
    }

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        calls.append((method, params))
        guard case .object(let p) = params, case .string(let surfaceId)? = p["surface_id"] else {
            return RPCResponse(id: "stub", ok: true, result: .object([:]))
        }
        switch method {
        case "surface.subscribe" where rejectedSurfaceIds.contains(surfaceId):
            return RPCResponse(id: "stub", ok: false, error: RPCError(
                code: "surface_subscription_failed",
                message: "subscribe rejected"
            ))
        case "surface.read_text" where gatedRead?.surfaceId == surfaceId:
            gatedReadStarted = true
            while !gatedReadReleased { await Task.yield() }
            return RPCResponse(id: "stub", ok: true, result: .object(["text": .string(gatedRead?.text ?? "")]))
        case "surface.read_text":
            return RPCResponse(id: "stub", ok: false, error: RPCError(
                code: "snapshot_unavailable",
                message: "no active subscription"
            ))
        default:
            return RPCResponse(id: "stub", ok: true, result: .object([:]))
        }
    }
}

private actor UnsubscribeGatingRPCDispatch: RPCDispatch {
    private(set) var calls: [(method: String, params: JSONValue)] = []
    private var holdNext = false
    private(set) var heldUnsubscribeStarted = false
    private var released = false

    func holdNextUnsubscribe() {
        holdNext = true
    }

    func releaseHeldUnsubscribe() {
        released = true
    }

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        calls.append((method, params))
        if method == "surface.unsubscribe", holdNext {
            holdNext = false
            heldUnsubscribeStarted = true
            while !released { await Task.yield() }
        }
        return RPCResponse(id: "stub", ok: true, result: .object([:]))
    }
}


/// Wraps the stub with cmux's polling refusal and a hold on `workspace.list`.
private actor RateLimitingRPCDispatch: RPCDispatch {
    private let stub = StubRPCDispatch()
    private var limitSurfaceList = false
    private var holdNext = false
    private(set) var heldWorkspaceListStarted = false
    private var released = false

    func setLimitSurfaceList(_ value: Bool) { limitSurfaceList = value }
    func holdNextWorkspaceList() { holdNext = true }
    func releaseWorkspaceList() { released = true }

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        if method == "surface.list", limitSurfaceList {
            return RPCResponse(id: "stub", ok: false, error: RPCError(
                code: "rate_limited",
                message: "Polling rate limited for this connection"
            ))
        }
        if method == "workspace.list", holdNext {
            holdNext = false
            heldWorkspaceListStarted = true
            while !released { await Task.yield() }
        }
        return try await stub.call(method: method, params: params)
    }
}
