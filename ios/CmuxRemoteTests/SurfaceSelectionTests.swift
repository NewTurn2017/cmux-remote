import XCTest
import SharedKit
@testable import CmuxRemote

@MainActor
final class SurfaceSelectionTests: XCTestCase {
    private let terminal = Surface(id: "t1", title: "shell", index: 1, type: "terminal")
    private let legacy = Surface(id: "t0", title: "old", index: 2)
    private let browser = Surface(id: "b1", title: "localhost:3000", index: 0, type: "browser")
    private let markdown = Surface(id: "m1", title: "README.md", index: 3, type: "markdown")

    private static let surfaceInputMethods: Set<String> = [
        "surface.subscribe", "surface.unsubscribe", "surface.focus",
        "surface.read_text", "surface.send_key", "surface.send_text",
    ]

    func testSurfaceListDecodesType() throws {
        let result: JSONValue = .object(["surfaces": .array([
            .object(["id": .string("a"), "title": .string("sh"), "index": .int(0), "type": .string("terminal")]),
            .object(["id": .string("b"), "title": .string("web"), "index": .int(1), "type": .string("browser")]),
            .object(["id": .string("c"), "title": .string("old"), "index": .int(2)]),
        ])])

        let surfaces = try result.decode(SurfaceListPayload.self).surfaces.map(\.model)

        XCTAssertEqual(surfaces.map(\.type), ["terminal", "browser", nil])
        XCTAssertEqual(surfaces.map(\.isTerminal), [true, false, true])
    }

    func testCreatedSurfaceMissingFromListIsTerminal() async throws {
        let store = WorkspaceStore(rpc: SurfaceRoutingRPCStub())

        let surface = try await store.createSurface(workspaceId: "w1")

        XCTAssertEqual(surface.id, "created")
        XCTAssertEqual(surface.type, "terminal")
        XCTAssertTrue(surface.isTerminal)
    }

    func testInitialSurfacePrefersFirstTerminalByIndex() {
        XCTAssertEqual(SurfaceSelectionPolicy.initialSurface(in: [markdown, legacy, browser, terminal]), terminal)
    }

    func testInitialSurfaceTreatsMissingTypeAsTerminal() {
        XCTAssertEqual(SurfaceSelectionPolicy.initialSurface(in: [browser, legacy]), legacy)
    }

    func testInitialSurfaceFallsBackToFirstSurfaceWithoutTerminals() {
        XCTAssertEqual(SurfaceSelectionPolicy.initialSurface(in: [markdown, browser]), browser)
        XCTAssertNil(SurfaceSelectionPolicy.initialSurface(in: []))
    }

    func testOpeningNonTerminalSurfaceMakesNoSurfaceCalls() async {
        let rpc = SurfaceRoutingRPCStub()
        let store = SurfaceStore(rpc: rpc)

        let browserRoute = await store.open(workspaceId: "w1", surface: browser)
        let markdownRoute = await store.open(workspaceId: "w1", surface: markdown)

        XCTAssertEqual(browserRoute, .placeholder)
        XCTAssertEqual(markdownRoute, .placeholder)
        XCTAssertEqual(store.placeholderSurfaceId, markdown.id)
        XCTAssertNil(store.subscribed)
        let calls = await rpc.calls
        XCTAssertTrue(calls.isEmpty, "\(calls.map(\.method))")
    }

    func testInputToNonTerminalSurfaceIsRefusedWithoutCalls() async {
        let rpc = SurfaceRoutingRPCStub()
        let store = SurfaceStore(rpc: rpc)
        await store.open(workspaceId: "w1", surface: browser)

        await assertRefused { try await store.sendKey(workspaceId: "w1", surfaceId: self.browser.id, key: .pageUp) }
        await assertRefused { try await store.sendText(workspaceId: "w1", surfaceId: self.browser.id, text: "ls") }
        await assertRefused {
            try await store.submitCommand(workspaceId: "w1", surfaceId: self.browser.id, command: "pwd")
        }
        await assertRefused { try await store.submitCommand(workspaceId: "w1", surfaceId: self.browser.id, command: "") }

        let calls = await rpc.calls
        XCTAssertTrue(calls.isEmpty, "\(calls.map(\.method))")
    }

    func testOpeningNonTerminalReleasesOnlyThePreviousTerminal() async {
        let rpc = SurfaceRoutingRPCStub()
        let store = SurfaceStore(rpc: rpc)
        await store.open(workspaceId: "w1", surface: terminal)
        let before = await rpc.calls.count

        await store.open(workspaceId: "w1", surface: browser)

        let after = Array(await rpc.calls.dropFirst(before))
        XCTAssertEqual(after.map(\.method), ["surface.unsubscribe"])
        XCTAssertEqual(after.first?.surfaceId, terminal.id)
        let browserCalls = await rpc.calls.filter { $0.surfaceId == browser.id }
        XCTAssertTrue(browserCalls.isEmpty)
    }

    func testNotTerminalPushEventSwitchesToPlaceholderAndUnsubscribes() async {
        let unsubscribed = expectation(description: "surface.unsubscribe sent")
        let rpc = SurfaceRoutingRPCStub(onUnsubscribe: { unsubscribed.fulfill() })
        let store = SurfaceStore(rpc: rpc)
        let route = await store.open(workspaceId: "w1", surface: legacy)
        XCTAssertEqual(route, .terminal)

        store.ingest(.event(Self.notTerminalEvent(surfaceId: legacy.id)))

        XCTAssertEqual(store.placeholderSurfaceId, legacy.id)
        XCTAssertNil(store.subscribed)
        XCTAssertNil(store.subscriptionError)
        XCTAssertTrue(store.reportedNotTerminalSurfaceIds.contains(legacy.id))
        await fulfillment(of: [unsubscribed], timeout: 2)
        let unsubscribes = await rpc.calls.filter { $0.method == "surface.unsubscribe" }
        XCTAssertEqual(unsubscribes.map(\.surfaceId), [legacy.id])

        store.ingest(.screenFull(Self.full(surfaceId: legacy.id, activeScreen: "primary")))
        XCTAssertNil(store.activeScreen)
        await assertRefused { try await store.sendKey(workspaceId: "w1", surfaceId: self.legacy.id, key: .enter) }
    }

    func testNotTerminalPushEventForAnotherSurfaceKeepsTheMirror() async {
        let store = SurfaceStore(rpc: SurfaceRoutingRPCStub())
        await store.open(workspaceId: "w1", surface: terminal)

        store.ingest(.event(Self.notTerminalEvent(surfaceId: "elsewhere")))

        XCTAssertEqual(store.subscribed, terminal.id)
        XCTAssertNil(store.placeholderSurfaceId)
    }

    func testNotTerminalRPCErrorSwitchesToPlaceholderAndUnsubscribes() async {
        let rpc = SurfaceRoutingRPCStub(notTerminalSubscribeIds: [legacy.id])
        let store = SurfaceStore(rpc: rpc)

        let route = await store.open(workspaceId: "w1", surface: legacy)

        XCTAssertEqual(route, .placeholder)
        XCTAssertEqual(store.placeholderSurfaceId, legacy.id)
        XCTAssertNil(store.subscribed)
        XCTAssertNil(store.subscriptionError)
        let calls = await rpc.calls
        XCTAssertEqual(calls.map(\.method), ["surface.subscribe", "surface.unsubscribe"])
        XCTAssertTrue(calls.allSatisfy { $0.surfaceId == legacy.id })
    }

    func testReportedNotTerminalSurfaceIsNeverResubscribed() async {
        let rpc = SurfaceRoutingRPCStub(notTerminalSubscribeIds: [legacy.id])
        let store = SurfaceStore(rpc: rpc)
        await store.open(workspaceId: "w1", surface: legacy)
        await store.open(workspaceId: "w1", surface: terminal)
        let before = await rpc.calls.count

        let route = await store.open(workspaceId: "w1", surface: legacy)

        XCTAssertEqual(route, .placeholder)
        let after = Array(await rpc.calls.dropFirst(before))
        XCTAssertEqual(after.map(\.method), ["surface.unsubscribe"])
        XCTAssertEqual(after.first?.surfaceId, terminal.id)
    }

    func testActiveScreenFollowsFullFramesAndSurvivesDiffs() async {
        let store = SurfaceStore(rpc: SurfaceRoutingRPCStub())
        await store.open(workspaceId: "w1", surface: terminal)
        XCTAssertNil(store.activeScreen)

        store.ingest(.screenFull(Self.full(surfaceId: terminal.id, activeScreen: "alternate")))
        XCTAssertEqual(store.activeScreen, "alternate")

        store.ingest(.screenDiff(ScreenDiff(surfaceId: terminal.id, rev: 3, ops: [.row(y: 0, text: "next")])))
        XCTAssertEqual(store.activeScreen, "alternate")

        store.ingest(.screenFull(Self.full(surfaceId: terminal.id, activeScreen: "primary")))
        XCTAssertEqual(store.activeScreen, "primary")

        store.ingest(.screenFull(Self.full(surfaceId: terminal.id, activeScreen: nil)))
        XCTAssertNil(store.activeScreen)
    }

    func testActiveScreenClearsOnSwitchResubscribeAndReset() async {
        let other = Surface(id: "t2", title: "logs", index: 4, type: "terminal")
        let store = SurfaceStore(rpc: SurfaceRoutingRPCStub())
        await store.open(workspaceId: "w1", surface: terminal)
        store.ingest(.screenFull(Self.full(surfaceId: terminal.id, activeScreen: "alternate")))

        await store.open(workspaceId: "w1", surface: other)
        XCTAssertNil(store.activeScreen, "surface switch")

        store.ingest(.screenFull(Self.full(surfaceId: other.id, activeScreen: "alternate")))
        await store.resubscribe()
        XCTAssertNil(store.activeScreen, "resubscribe")

        store.ingest(.screenFull(Self.full(surfaceId: other.id, activeScreen: "alternate")))
        await store.open(workspaceId: "w1", surface: other)
        XCTAssertNil(store.activeScreen, "re-selecting the same surface")

        store.ingest(.screenFull(Self.full(surfaceId: other.id, activeScreen: "alternate")))
        await store.open(workspaceId: "w1", surface: browser)
        XCTAssertNil(store.activeScreen, "switch to placeholder")

        await store.open(workspaceId: "w1", surface: other)
        store.ingest(.screenFull(Self.full(surfaceId: other.id, activeScreen: "alternate")))
        store.reset()
        XCTAssertNil(store.activeScreen, "connection reset")
    }

    private func assertRefused(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Input to a non-terminal surface must be refused", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SurfaceInputError, .notTerminal, file: file, line: line)
        }
    }

    private static func notTerminalEvent(surfaceId: String) -> EventFrame {
        EventFrame(category: .surface, name: "surface_not_terminal", payload: .object([
            "code": .string("surface_not_terminal"),
            "surface_id": .string(surfaceId),
            "workspace_id": .string("w1"),
        ]))
    }

    private static func full(surfaceId: String, activeScreen: String?) -> ScreenFull {
        ScreenFull(
            surfaceId: surfaceId,
            rev: 2,
            rows: ["frame", ""],
            cols: 12,
            rowsCount: 2,
            cursor: CursorPos(x: 0, y: 0),
            activeScreen: activeScreen
        )
    }
}

private actor SurfaceRoutingRPCStub: RPCDispatch {
    struct Call {
        let method: String
        let params: JSONValue

        var surfaceId: String? {
            guard case .object(let params) = params, case .string(let id)? = params["surface_id"] else { return nil }
            return id
        }
    }

    private(set) var calls: [Call] = []
    private let notTerminalSubscribeIds: Set<String>
    private let onUnsubscribe: @Sendable () -> Void

    init(notTerminalSubscribeIds: Set<String> = [], onUnsubscribe: @escaping @Sendable () -> Void = {}) {
        self.notTerminalSubscribeIds = notTerminalSubscribeIds
        self.onUnsubscribe = onUnsubscribe
    }

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        let call = Call(method: method, params: params)
        calls.append(call)
        switch method {
        case "surface.subscribe" where call.surfaceId.map(notTerminalSubscribeIds.contains) == true:
            return RPCResponse(id: "stub", ok: false, error: RPCError(
                code: "surface_not_terminal",
                message: "Surface is not a terminal"
            ))
        case "surface.unsubscribe":
            onUnsubscribe()
        case "surface.create":
            return RPCResponse(id: "stub", ok: true, result: .object(["surface_id": .string("created")]))
        case "surface.list":
            return RPCResponse(id: "stub", ok: true, result: .object(["surfaces": .array([])]))
        default:
            break
        }
        return RPCResponse(id: "stub", ok: true, result: .object([:]))
    }
}
