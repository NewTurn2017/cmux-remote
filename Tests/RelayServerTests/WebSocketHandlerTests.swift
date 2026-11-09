import XCTest
import Crypto
import Darwin
import Foundation
import SharedKit
@testable import RelayServer
@testable import RelayCore

final class WebSocketHandlerTests: XCTestCase {

    // MARK: - Hello flow

    func testHelloMissedReturnsClose() async {
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        let actions = await m.helloMissed()
        XCTAssertEqual(actions, [.close])
    }

    func testValidHelloEmitsAttach() async {
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        let json = #"{"deviceId":"d-7","appVersion":"1.0.0","protocolVersion":1}"#
        let actions = await m.processText(json)
        XCTAssertEqual(actions, [.attachSession(deviceId: "d-7")])
    }

    func testInvalidFirstFrameClosesBeforeHello() async {
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        let actions = await m.processText("not json")
        XCTAssertEqual(actions, [.close])
    }

    func testFirstFrameWrongShapeClosesBeforeHello() async {
        // Looks like JSON but isn't a HelloFrame.
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        let actions = await m.processText(#"{"id":"1","method":"workspace.list","params":{}}"#)
        XCTAssertEqual(actions, [.close])
    }

    func testHelloMissedAfterHelloIsNoop() async {
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)
        let actions = await m.helloMissed()
        XCTAssertEqual(actions, [])
    }

    // MARK: - RPC dispatch

    func testRPCDispatchesToFacade() async {
        let cmux = RecordingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"1","method":"workspace.list","params":{}}"#)

        let calls = await cmux.snapshot()
        XCTAssertEqual(calls.map(\.method), ["workspace.list"])
        XCTAssertEqual(actions.count, 1)
        guard case .sendText(let s) = actions[0] else {
            return XCTFail("expected sendText, got \(actions[0])")
        }
        XCTAssertTrue(s.contains(#""id":"1""#), "missing id: \(s)")
        XCTAssertTrue(s.contains(#""ok":true"#), "missing ok=true: \(s)")
    }

    func testRPCErrorYieldsErrorResponse() async {
        let cmux = ThrowingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"7","method":"surface.send_text","params":{}}"#)
        XCTAssertEqual(actions.count, 1)
        guard case .sendText(let s) = actions[0] else {
            return XCTFail("expected sendText, got \(actions[0])")
        }
        XCTAssertTrue(s.contains(#""ok":false"#), "missing ok=false: \(s)")
        XCTAssertTrue(s.contains(#""code":"internal_error""#), "missing code: \(s)")
    }

    func testCmuxRPCErrorCodeIsPassedThrough() async {
        let m = WSProtocolMachine(cmux: RateLimitedCMUXFacade())
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"8","method":"surface.list","params":{}}"#)
        guard case .sendText(let s)? = actions.first else {
            return XCTFail("expected sendText, got \(actions)")
        }
        XCTAssertTrue(s.contains(#""code":"rate_limited""#), "missing code: \(s)")
        XCTAssertTrue(s.contains(#""retry_after_ms":40"#), "missing data: \(s)")
    }

    func testGarbageAfterHelloIsIgnored() async {
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)
        let actions = await m.processText("not json")
        XCTAssertEqual(actions, [])
    }

    func testSurfaceSubscribeBecomesRelayActionWithoutCmuxDispatch() async {
        let cmux = RecordingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"9","method":"surface.subscribe","params":{"workspace_id":"w","surface_id":"s","fps":15}}"#)

        let calls = await cmux.snapshot()
        XCTAssertEqual(calls, [])
        XCTAssertEqual(actions, [.subscribe(responseId: "9", workspaceId: "w", surfaceId: "s", lines: 200)])
    }

    func testLegacyPageKeysAreNormalizedBeforeDispatch() async throws {
        let cmux = ParamsRecordingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)
        let sent = ["pgup", "pgdn", "pagedown", "page_up", "page_down", "ctrl+c", "alt+up", "enter"]

        for (index, key) in sent.enumerated() {
            _ = await m.processText(
                #"{"id":"k\#(index)","method":"surface.send_key","params":{"workspace_id":"w","surface_id":"s","key":"\#(key)"}}"#
            )
        }

        let forwarded = await cmux.snapshot().map { call -> String? in
            guard case .object(let params) = call.params, case .string(let key)? = params["key"] else { return nil }
            return key
        }
        XCTAssertEqual(forwarded, ["page_up", "page_down", "page_down", "page_up", "page_down", "ctrl+c", "alt+up", "enter"])
    }

    func testNonSendKeyRequestsPassThroughUnchanged() {
        let request = RPCRequest(id: "1", method: "surface.send_text",
                                 params: .object(["surface_id": .string("s"), "text": .string("pgdn")]))
        XCTAssertEqual(WSProtocolMachine.daemonCompatibleParams(for: request), request.params)
    }

    func testSurfaceNotTerminalSubscriptionFailureUsesStableWireShape() throws {
        let response = WebSocketSessionLifecycle.subscriptionFailureResponse(
            id: "r1",
            error: SurfaceRenderHubError.surfaceNotTerminal(surfaceId: "s")
        )
        let wire = try XCTUnwrap(String(data: SharedKitJSON.deterministicEncoder.encode(response), encoding: .utf8))
        XCTAssertEqual(
            wire,
            #"{"error":{"code":"surface_not_terminal","data":{"surface_id":"s"},"message":"Surface is not a terminal"},"id":"r1","ok":false}"#
        )

        let other = WebSocketSessionLifecycle.subscriptionFailureResponse(
            id: "r2",
            error: SurfaceRenderHubError.surfaceLimitReached(4)
        )
        XCTAssertEqual(other.error?.code, "surface_subscription_failed")
    }

    func testSurfaceSubscribeUsesRequestedLineCount() async {
        let cmux = RecordingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"9","method":"surface.subscribe","params":{"workspace_id":"w","surface_id":"s","fps":15,"lines":120}}"#)

        let calls = await cmux.snapshot()
        XCTAssertEqual(calls, [])
        XCTAssertEqual(actions, [.subscribe(responseId: "9", workspaceId: "w", surfaceId: "s", lines: 120)])
    }

    func testSurfaceUnsubscribeBecomesRelayActionWithoutCmuxDispatch() async {
        let cmux = RecordingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"10","method":"surface.unsubscribe","params":{"surface_id":"s"}}"#)

        let calls = await cmux.snapshot()
        XCTAssertEqual(calls, [])
        XCTAssertEqual(actions, [.unsubscribe(responseId: "10", surfaceId: "s")])
    }

    func testSurfaceReadTextRequestsRetainedAuthoritativeFullWithoutCmuxDispatch() async {
        let cmux = RecordingCMUXFacade()
        let machine = WSProtocolMachine(cmux: cmux)
        _ = await machine.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await machine.processText(
            #"{"id":"read","method":"surface.read_text","params":{"workspace_id":"w","surface_id":"s","lines":120}}"#
        )

        let calls = await cmux.snapshot()
        XCTAssertEqual(actions, [.requestFull(responseId: "read", surfaceId: "s")])
        XCTAssertEqual(calls, [])
    }

    func testSuccessfulTerminalInputNotesSubscribedSurfaceAfterResponse() async {
        let cmux = RecordingCMUXFacade()
        let machine = WSProtocolMachine(cmux: cmux)
        _ = await machine.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await machine.processText(
            #"{"id":"input","method":"surface.send_text","params":{"surface_id":"s","text":"ls\\n"}}"#
        )

        XCTAssertEqual(actions.count, 2)
        guard case .sendText = actions.first else {
            return XCTFail("successful input must send its RPC response first")
        }
        let calls = await cmux.snapshot()
        XCTAssertEqual(actions.last, .noteUserInput(surfaceId: "s"))
        XCTAssertEqual(calls.map(\.method), ["surface.send_text"])
    }

    func testAdvertisesRelayOwnedCapabilitiesWithoutCmuxDispatch() async throws {
        let cmux = RecordingCMUXFacade()
        let machine = WSProtocolMachine(cmux: cmux)
        _ = await hello(machine)

        let response = try await rpc(machine, id: "cap", method: "host.capabilities", params: .object([:]))
        let capabilities = try response.decodeResult(HostCapabilitiesResult.self)

        expect(capabilities.capabilities == [
            "file.upload.v2", "terminal.artifact.v1", "surface.document.v1", "surface.browser.v1", "feed.v1", "claude.transcript.v1",
        ])
        expect(capabilities.supportsSurfaceDocumentV1)
        expect(capabilities.supportsSurfaceBrowserV1)
        expect(capabilities.supportsFeedV1)
        expect(capabilities.supportsClaudeTranscriptV1)
        expect(await cmux.snapshot() == [])
    }

    func testRelayUpdateRPCsAnswerMethodNotFoundUntilTheUpdaterShips() async throws {
        let cmux = RecordingCMUXFacade()
        let machine = WSProtocolMachine(cmux: cmux)
        _ = await hello(machine)

        for method in [RemoteRPCMethod.relayInfo, .relayUpdateStart] {
            let request = RPCRequest(id: method.rawValue, method: method.rawValue, params: .object([:]))
            let actions = await machine.processText(try require(String(data: JSONEncoder().encode(request), encoding: .utf8)))
            XCTAssertEqual(actions.count, 1)
            guard case .sendText(let wire) = try require(actions.first) else {
                return XCTFail("expected sendText, got \(actions)")
            }
            print("RELAY_UPDATE_WIRE_SAMPLE placeholder-\(method.rawValue) \(wire)")
            let response = try JSONDecoder().decode(RPCResponse.self, from: Data(wire.utf8))
            XCTAssertEqual(response.ok, false)
            XCTAssertEqual(response.error?.code, RemoteErrorCode.methodNotFound.rawValue)
        }

        let capabilities = try await rpc(machine, id: "cap", method: "host.capabilities", params: .object([:]))
            .decodeResult(HostCapabilitiesResult.self)
        expect(!capabilities.supportsRelayInfoV1)
        expect(!capabilities.supportsRelayUpdateV1)
        expect(await cmux.snapshot() == [])
    }

    func testSurfaceDocumentOpenIgnoresClientSuppliedPath() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = Data("# Probe\n\nhello **md**\n".utf8)
        let document = directory.appendingPathComponent("probe.md")
        try content.write(to: document)
        let cmux = RecordingCMUXFacade()
        let machine = WSProtocolMachine(
            cmux: cmux,
            authenticatedDeviceID: "document-device",
            uploadService: ChunkedFileUploadService(rootURL: directory),
            artifactService: documentArtifactService(surfaces: [
                "S": .object(["kind": .string("markdown"), "file_path": .string(document.path)]),
            ])
        )
        _ = await hello(machine)

        let response = try await rpc(machine, id: "doc", method: RemoteRPCMethod.surfaceDocumentOpen.rawValue, params: .object([
            "workspace_id": .string("W"),
            "surface_id": .string("S"),
            "path": .string("/etc/hosts"),
            "file_path": .string("/etc/hosts"),
            "filename": .string("hosts"),
        ]))
        let opened = try response.decodeResult(TerminalArtifactScanResult.self)
        let artifact = try require(opened.artifacts.first)
        let chunk = try await typedRPC(
            machine,
            id: "doc-fetch",
            method: RemoteRPCMethod.artifactFetch.rawValue,
            payload: TerminalArtifactFetchRequest(artifactId: artifact.artifactId, offset: 0),
            result: TerminalArtifactFetchResult.self
        )

        XCTAssertEqual(opened.artifacts.count, 1)
        XCTAssertEqual(artifact.filename, "probe.md")
        XCTAssertEqual(artifact.mimeType, "text/markdown")
        XCTAssertEqual(artifact.bytes, content.count)
        XCTAssertFalse(artifact.isImage)
        XCTAssertEqual(try chunk.decodedBytes(), content)
        XCTAssertEqual(chunk.totalBytes, artifact.bytes)
        XCTAssertEqual(chunk.revision, artifact.revision)
        XCTAssertTrue(chunk.eof)
        expect(await cmux.snapshot() == [])
    }

    func testSurfaceDocumentOpenErrorCodesOnWire() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oversized = directory.appendingPathComponent("large.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(TerminalArtifactService.maximumDocumentBytes + 1))
        try handle.close()
        let machine = WSProtocolMachine(
            cmux: RecordingCMUXFacade(),
            authenticatedDeviceID: "document-device",
            uploadService: ChunkedFileUploadService(rootURL: directory),
            artifactService: documentArtifactService(surfaces: [
                "terminal": .object(["kind": .string("terminal"), "file_path": .null]),
                "missing": .object([
                    "kind": .string("markdown"),
                    "file_path": .string(directory.appendingPathComponent("gone.md").path),
                ]),
                "large": .object(["kind": .string("markdown"), "file_path": .string(oversized.path)]),
            ])
        )
        _ = await hello(machine)
        func open(_ surface: String, workspace: String = "W") async throws -> RPCResponse {
            try await rpc(machine, id: "doc-\(surface)", method: RemoteRPCMethod.surfaceDocumentOpen.rawValue, params: .object([
                "workspace_id": .string(workspace), "surface_id": .string(surface),
            ]))
        }

        let terminal = try await open("terminal")
        let unknown = try await open("unknown")
        let missing = try await open("missing")
        let large = try await open("large")
        let emptyWorkspace = try await open("terminal", workspace: "")
        let unsupportedMachine = WSProtocolMachine(
            cmux: RecordingCMUXFacade(),
            authenticatedDeviceID: "document-device",
            uploadService: ChunkedFileUploadService(rootURL: directory),
            artifactService: TerminalArtifactService(dispatchNative: { _, _ in .failure(code: "method_not_found") })
        )
        _ = await hello(unsupportedMachine)
        let unsupported = try await rpc(unsupportedMachine, id: "doc-old", method: RemoteRPCMethod.surfaceDocumentOpen.rawValue, params: .object([
            "workspace_id": .string("W"), "surface_id": .string("S"),
        ]))

        XCTAssertEqual(terminal.error?.code, "surface_not_document")
        XCTAssertEqual(terminal.error?.data, .object(["field": .string("surface_id")]))
        XCTAssertEqual(unknown.error?.code, "surface_not_document")
        XCTAssertEqual(unsupported.error?.code, "surface_not_document")
        XCTAssertEqual(missing.error?.code, "not_found")
        XCTAssertEqual(large.error?.code, "size_limit_exceeded")
        XCTAssertEqual(large.error?.data, .object([
            "field": .string("bytes"), "max_bytes": .int(16 * 1_024 * 1_024),
        ]))
        XCTAssertEqual(emptyWorkspace.error?.code, "invalid_field")
        for response in [terminal, unknown, unsupported, missing, large, emptyWorkspace] {
            XCTAssertEqual(response.ok, false)
            XCTAssertFalse(response.error?.message.contains(directory.path) ?? true)
            XCTAssertFalse(response.error?.message.contains("/") ?? true)
        }
    }

    func testSurfaceBrowserCaptureReturnsTheContractResultAndIgnoresClientFields() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cmux = FakeBrowserCMUX(screenshots: [
            "S": FakeBrowserCMUX.screenshot(png: BrowserCaptureTestImages.png(width: 2318, height: 2640), path: nil),
        ])
        let machine = browserMachine(directory: directory, cmux: cmux)
        _ = await hello(machine)
        let request = RPCRequest(id: "cap-1", method: RemoteRPCMethod.surfaceBrowserCapture.rawValue, params: .object([
            "workspace_id": .string("W"), "surface_id": .string("S"), "path": .string("/etc/hosts"),
        ]))

        let response = try await rpc(machine, id: request.id, method: request.method, params: request.params)
        let result = try response.decodeResult(SurfaceBrowserCaptureResult.self)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(result.mimeType, "image/jpeg")
        XCTAssertEqual(result.width, 1405)
        XCTAssertEqual(result.height, 1600)
        XCTAssertEqual(result.sourceWidth, 2318)
        XCTAssertEqual(result.sourceHeight, 2640)
        XCTAssertEqual(result.url, FakeBrowserCMUX.pageURL)
        XCTAssertEqual(result.title, FakeBrowserCMUX.pageTitle)
        XCTAssertEqual(result.capturedAt, 1_794_240_000_000)
        XCTAssertLessThanOrEqual(try result.decodedImage().count, SurfaceBrowserCaptureLimits.maxImageBytes)
        let screenshotCall = await cmux.calls.first
        XCTAssertEqual(screenshotCall?.method, "browser.screenshot")
        XCTAssertEqual(screenshotCall?.params, JSONValue.object(["workspace_id": .string("W"), "surface_id": .string("S")]))
        try printBrowserWireSample("request", request)
        try printBrowserWireSample("success", response)
    }

    func testSurfaceBrowserCaptureErrorCodesOnWire() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cmux = FakeBrowserCMUX(screenshots: [
            "terminal": .failure(code: "invalid_params"),
            "limited": .failure(code: "rate_limited"),
            "tiny": FakeBrowserCMUX.screenshot(png: BrowserCaptureTestImages.png(width: 64, height: 64), path: nil),
        ])
        let machine = WSProtocolMachine(
            cmux: RecordingCMUXFacade(),
            authenticatedDeviceID: "browser-device",
            uploadService: ChunkedFileUploadService(rootURL: directory),
            artifactService: inertArtifactService(cmux: RecordingCMUXFacade()),
            browserCaptureService: BrowserCaptureService(dispatch: cmux.dispatch, maxImageBytes: 10)
        )
        _ = await hello(machine)
        func capture(_ params: [String: JSONValue], id: String) async throws -> RPCResponse {
            try await rpc(machine, id: id, method: RemoteRPCMethod.surfaceBrowserCapture.rawValue, params: .object(params))
        }

        let terminal = try await capture(["workspace_id": .string("W"), "surface_id": .string("terminal")], id: "cap-2")
        let unknown = try await capture(["workspace_id": .string("W"), "surface_id": .string("closed")], id: "cap-3")
        let limited = try await capture(["workspace_id": .string("W"), "surface_id": .string("limited")], id: "cap-4")
        let oversized = try await capture(["workspace_id": .string("W"), "surface_id": .string("tiny")], id: "cap-5")
        let emptyWorkspace = try await capture(["workspace_id": .string(""), "surface_id": .string("S")], id: "cap-6")
        let missingSurface = try await capture(["workspace_id": .string("W")], id: "cap-7")

        XCTAssertEqual(terminal.error?.code, "surface_not_browser")
        XCTAssertEqual(terminal.error?.data, .object(["field": .string("surface_id")]))
        XCTAssertEqual(unknown.error?.code, "surface_not_browser")
        XCTAssertEqual(limited.error?.code, "rate_limited")
        XCTAssertEqual(oversized.error?.code, "size_limit_exceeded")
        XCTAssertEqual(oversized.error?.data, .object([
            "field": .string("image_base64"), "max_bytes": .int(737_280),
        ]))
        XCTAssertEqual(emptyWorkspace.error?.code, "invalid_field")
        XCTAssertEqual(emptyWorkspace.error?.data, .object(["field": .string("workspace_id")]))
        XCTAssertEqual(missingSurface.error?.code, "invalid_request")
        for response in [terminal, unknown, limited, oversized, emptyWorkspace, missingSurface] {
            XCTAssertEqual(response.ok, false)
            let message = response.error?.message ?? "/"
            XCTAssertFalse(message.contains("/"))
            XCTAssertFalse(message.contains(FakeBrowserCMUX.pageURL))
            XCTAssertFalse(message.contains(FakeBrowserCMUX.pageTitle))
        }
        try printBrowserWireSample("surface_not_browser", terminal)
        try printBrowserWireSample("rate_limited", limited)
        try printBrowserWireSample("size_limit_exceeded", oversized)
    }

    func testSurfaceBrowserCaptureDeadlineAnswersAndLaterFramesStillRun() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let browser = FakeBrowserCMUX(
            screenshots: ["S": FakeBrowserCMUX.screenshot(png: BrowserCaptureTestImages.png(width: 64, height: 64), path: nil)],
            gate: gate.stream
        )
        let facade = RecordingCMUXFacade()
        let machine = WSProtocolMachine(
            cmux: facade,
            authenticatedDeviceID: "browser-device",
            uploadService: ChunkedFileUploadService(rootURL: directory),
            artifactService: inertArtifactService(cmux: facade),
            browserCaptureService: BrowserCaptureService(dispatch: browser.dispatch),
            relayOwnedTimeout: .milliseconds(100)
        )
        _ = await hello(machine)

        let blocked = try await rpc(machine, id: "cap-8", method: RemoteRPCMethod.surfaceBrowserCapture.rawValue, params: .object([
            "workspace_id": .string("W"), "surface_id": .string("S"),
        ]))
        let next = try await rpc(machine, id: "after", method: "workspace.list", params: .object([:]))

        XCTAssertEqual(blocked.error?.code, WSProtocolMachine.temporarilyUnavailableCode)
        XCTAssertEqual(blocked.error?.message, "Browser capture did not finish in time")
        XCTAssertEqual(next.ok, true)
        expect(await facade.snapshot() == [.init(method: "workspace.list")])
        try printBrowserWireSample("temporarily_unavailable", blocked)
    }

    func testFeedPendingListAndReplyOnTheWire() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cmux = FakeFeedCMUX(items: [
            FeedRaw.item(id: "item-q1", kind: "question", requestId: "req-q1", createdAt: "2026-11-09T10:00:03Z", [
                "title": .string("Question"),
                "questions": .array([FeedRaw.question("q1", prompt: "Which approach?", options: [
                    FeedRaw.option("o1", "Option A"), FeedRaw.option("o2", "Option B"),
                ])]),
            ]),
            FeedRaw.item(id: "item-p1", kind: "permissionRequest", requestId: "req-p1", createdAt: "2026-11-09T10:00:02Z", [
                "title": .string("Permission: Bash"), "tool_name": .string("Bash"),
                "tool_input": .object(["command": .string("npm test")]),
            ]),
            FeedRaw.item(id: "item-x1", kind: "exitPlan", requestId: "req-x1", createdAt: "2026-11-09T10:00:01Z", [
                "plan": .string("1. Read\n2. Edit\n3. Test"), "default_mode": .string("manual"),
            ]),
        ])
        let machine = feedMachine(directory: directory, cmux: cmux)
        _ = await hello(machine)

        let listRequest = RPCRequest(id: "f-1", method: RemoteRPCMethod.feedPendingList.rawValue, params: .object(["limit": .int(50)]))
        let list = try await rpc(machine, id: listRequest.id, method: listRequest.method, params: listRequest.params)
        let pending = try list.decodeResult(FeedPendingListResult.self)
        XCTAssertEqual(pending.items.map(\.id), ["item-q1", "item-p1", "item-x1"])
        XCTAssertEqual(pending.items[1].toolInput, #"{"command":"npm test"}"#)
        XCTAssertEqual(pending.items[2].availableModes, ["autoAccept", "manual", "deny"])
        XCTAssertLessThanOrEqual(
            try JSONEncoder().encode(list).count,
            FeedLimits.maxResponseBytes
        )

        let replyRequest = RPCRequest(id: "r-1", method: RemoteRPCMethod.feedReply.rawValue, params: .object([
            "request_id": .string("req-q1"), "kind": .string("question"), "selections": .array([.string("Option A")]),
        ]))
        let replied = try await rpc(machine, id: replyRequest.id, method: replyRequest.method, params: replyRequest.params)
        XCTAssertEqual(try replied.decodeResult(FeedReplyResult.self), FeedReplyResult(requestId: "req-q1", kind: .question))

        let bypass = try await rpc(machine, id: "r-2", method: RemoteRPCMethod.feedReply.rawValue, params: .object([
            "request_id": .string("req-p1"), "kind": .string("permission"), "mode": .string("bypass"),
        ]))
        let gone = try await rpc(machine, id: "r-3", method: RemoteRPCMethod.feedReply.rawValue, params: .object([
            "request_id": .string("req-q1"), "kind": .string("question"), "selections": .array([.string("Option A")]),
        ]))
        let ultraplan = try await rpc(machine, id: "r-4", method: RemoteRPCMethod.feedReply.rawValue, params: .object([
            "request_id": .string("req-x1"), "kind": .string("plan"), "mode": .string("ultraplan"),
        ]))
        let badLimit = try await rpc(machine, id: "f-2", method: RemoteRPCMethod.feedPendingList.rawValue, params: .object(["limit": .int(0)]))

        XCTAssertEqual(bypass.error?.code, "invalid_field")
        XCTAssertEqual(bypass.error?.data, .object(["field": .string("mode")]))
        XCTAssertEqual(gone.error?.code, "feed_request_not_pending")
        XCTAssertEqual(gone.error?.data, .object(["field": .string("request_id")]))
        XCTAssertEqual(ultraplan.error?.code, "invalid_field")
        XCTAssertEqual(badLimit.error?.data, .object(["field": .string("limit")]))
        for response in [bypass, gone, ultraplan, badLimit] {
            let message = response.error?.message ?? "Option A"
            XCTAssertFalse(message.contains("Option A"))
            XCTAssertFalse(message.contains("npm test"))
            XCTAssertFalse(message.contains("/"))
        }
        expect(await cmux.replyCount() == 1)
        expect(await cmux.count(of: "feed.list") == 3)

        try printFeedWireSample("list_request", listRequest)
        try printFeedWireSample("list_success", list)
        try printFeedWireSample("reply_request", replyRequest)
        try printFeedWireSample("reply_success", replied)
        try printFeedWireSample("invalid_field", bypass)
        try printFeedWireSample("feed_request_not_pending", gone)
    }

    func testFeedPendingDeadlineAnswersAndLaterFramesStillRun() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let feed = FakeFeedCMUX(items: [], listGate: gate.stream)
        let facade = RecordingCMUXFacade()
        let machine = WSProtocolMachine(
            cmux: facade,
            authenticatedDeviceID: "feed-device",
            uploadService: ChunkedFileUploadService(rootURL: directory),
            artifactService: inertArtifactService(cmux: facade),
            feedService: FeedService(dispatch: feed.dispatch),
            relayOwnedTimeout: .milliseconds(100)
        )
        _ = await hello(machine)

        let blockedList = try await rpc(machine, id: "f-3", method: RemoteRPCMethod.feedPendingList.rawValue, params: .object([:]))
        let blockedReply = try await rpc(machine, id: "r-5", method: RemoteRPCMethod.feedReply.rawValue, params: .object([
            "request_id": .string("req"), "kind": .string("plan"), "mode": .string("manual"),
        ]))
        let next = try await rpc(machine, id: "after", method: "workspace.list", params: .object([:]))

        for blocked in [blockedList, blockedReply] {
            XCTAssertEqual(blocked.error?.code, WSProtocolMachine.temporarilyUnavailableCode)
            XCTAssertEqual(blocked.error?.message, "cmux feed did not answer in time")
        }
        XCTAssertEqual(next.ok, true)
        expect(await facade.snapshot() == [.init(method: "workspace.list")])
        try printFeedWireSample("temporarily_unavailable", blockedList)
    }

    func testClaudeSessionsAndTranscriptPageOnTheWire() async throws {
        let sandbox = try TranscriptSandbox()
        defer { sandbox.remove() }
        let file = sandbox.project.appendingPathComponent("00000000-0000-4000-8000-000000000001.jsonl")
        try TranscriptFixture.data().write(to: file)
        let vault = FakeVaultCMUX(sessions: [
            TranscriptLine.vaultSession("00000000-0000-4000-8000-000000000001", file: file.path, title: "README 정리"),
            TranscriptLine.vaultSession("outside", file: "/etc/hosts.jsonl"),
        ])
        let machine = claudeMachine(directory: sandbox.base, vault: vault, root: sandbox.root.path)
        _ = await hello(machine)

        let listRequest = RPCRequest(id: "c-1", method: RemoteRPCMethod.claudeSessionsList.rawValue, params: .object(["limit": .int(20)]))
        let list = try await rpc(machine, id: listRequest.id, method: listRequest.method, params: listRequest.params)
        let sessions = try list.decodeResult(ClaudeSessionListResult.self)
        XCTAssertEqual(sessions.sessions.map(\.sessionId), ["00000000-0000-4000-8000-000000000001"])

        let pageRequest = RPCRequest(id: "c-2", method: RemoteRPCMethod.claudeTranscriptPage.rawValue, params: .object([
            "session_id": .string("00000000-0000-4000-8000-000000000001"), "max_entries": .int(4),
        ]))
        let pageResponse = try await rpc(machine, id: pageRequest.id, method: pageRequest.method, params: pageRequest.params)
        let page = try pageResponse.decodeResult(ClaudeTranscriptPageResult.self)
        XCTAssertEqual(page.entries.map(\.id), ["u2", "a3", "u3", "a4"])
        let before = try require(page.before)
        XCTAssertEqual(page.fileSize, 25_960)

        let olderRequest = RPCRequest(id: "c-3", method: RemoteRPCMethod.claudeTranscriptPage.rawValue, params: .object([
            "session_id": .string("00000000-0000-4000-8000-000000000001"), "before": .int(before), "max_entries": .int(4),
        ]))
        let older = try await rpc(machine, id: olderRequest.id, method: olderRequest.method, params: olderRequest.params)
        let olderPage = try older.decodeResult(ClaudeTranscriptPageResult.self)
        XCTAssertEqual(olderPage.entries.map(\.id), ["u1", "a2"])
        XCTAssertNil(olderPage.before)

        let unknown = try await rpc(machine, id: "c-4", method: RemoteRPCMethod.claudeTranscriptPage.rawValue, params: .object([
            "session_id": .string("outside"),
        ]))
        let pastEnd = try await rpc(machine, id: "c-5", method: RemoteRPCMethod.claudeTranscriptPage.rawValue, params: .object([
            "session_id": .string("00000000-0000-4000-8000-000000000001"), "before": .int(26_000),
        ]))
        let badEntries = try await rpc(machine, id: "c-6", method: RemoteRPCMethod.claudeTranscriptPage.rawValue, params: .object([
            "session_id": .string("00000000-0000-4000-8000-000000000001"), "max_entries": .int(0),
        ]))
        let badId = try await rpc(machine, id: "c-7", method: RemoteRPCMethod.claudeTranscriptPage.rawValue, params: .object([
            "session_id": .string("../escape"),
        ]))

        XCTAssertEqual(unknown.error?.code, "claude_session_not_found")
        XCTAssertEqual(unknown.error?.data, .object(["field": .string("session_id")]))
        XCTAssertEqual(pastEnd.error?.code, "invalid_field")
        XCTAssertEqual(pastEnd.error?.data, .object(["field": .string("before")]))
        XCTAssertEqual(badEntries.error?.data, .object(["field": .string("max_entries")]))
        XCTAssertEqual(badId.error?.data, .object(["field": .string("session_id")]))
        for response in [list, pageResponse, older] {
            let text = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
            XCTAssertFalse(text.contains(sandbox.base.path))
            XCTAssertFalse(text.contains("resume"))
            XCTAssertLessThanOrEqual(text.utf8.count, ClaudeTranscriptLimits.maxResponseBytes)
        }
        for response in [unknown, pastEnd, badEntries, badId] {
            XCTAssertFalse((response.error?.message ?? "/").contains("/"))
        }
        expect(await vault.calls.count == 2)

        try printClaudeWireSample("sessions_request", listRequest)
        try printClaudeWireSample("sessions_success", list)
        try printClaudeWireSample("page_request", pageRequest)
        try printClaudeWireSample("page_success", pageResponse)
        try printClaudeWireSample("older_page_request", olderRequest)
        try printClaudeWireSample("older_page_success", older)
        try printClaudeWireSample("claude_session_not_found", unknown)
        try printClaudeWireSample("invalid_field_before", pastEnd)
    }

    func testClaudeTranscriptDeadlineAnswersAndLaterFramesStillRun() async throws {
        let sandbox = try TranscriptSandbox()
        defer { sandbox.remove() }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let vault = FakeVaultCMUX(sessions: [], gate: gate.stream)
        let facade = RecordingCMUXFacade()
        let machine = WSProtocolMachine(
            cmux: facade,
            authenticatedDeviceID: "claude-device",
            uploadService: ChunkedFileUploadService(rootURL: sandbox.base),
            artifactService: inertArtifactService(cmux: facade),
            claudeTranscriptService: ClaudeTranscriptService(dispatch: vault.dispatch, root: sandbox.root.path, log: { _ in }),
            relayOwnedTimeout: .milliseconds(100)
        )
        _ = await hello(machine)

        let blockedList = try await rpc(machine, id: "c-8", method: RemoteRPCMethod.claudeSessionsList.rawValue, params: .object([:]))
        let blockedPage = try await rpc(machine, id: "c-9", method: RemoteRPCMethod.claudeTranscriptPage.rawValue, params: .object([
            "session_id": .string("waiting"),
        ]))
        let next = try await rpc(machine, id: "after", method: "workspace.list", params: .object([:]))

        for blocked in [blockedList, blockedPage] {
            XCTAssertEqual(blocked.error?.code, WSProtocolMachine.temporarilyUnavailableCode)
            XCTAssertEqual(blocked.error?.message, "Claude transcript did not load in time")
        }
        XCTAssertEqual(next.ok, true)
        expect(await facade.snapshot() == [.init(method: "workspace.list")])
        try printClaudeWireSample("temporarily_unavailable", blockedPage)
    }

    func testAuthenticatedDeviceCanUploadMultipleChunksCommitAndCancel() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cmux = RecordingCMUXFacade()
        let uploadService = ChunkedFileUploadService(rootURL: directory)
        let machine = WSProtocolMachine(
            cmux: cmux,
            authenticatedDeviceID: "authenticated-device",
            uploadService: uploadService,
            artifactService: inertArtifactService(cmux: cmux)
        )
        _ = await hello(machine)

        let bytes = Data("multi-chunk payload".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let begin = try await typedRPC(
            machine, id: "begin", method: "file.upload.begin",
            payload: ChunkUploadBeginRequest(
                batchId: UUID().uuidString,
                filename: "fixture.bin", mimeType: "application/octet-stream", bytes: bytes.count,
                sha256: digest, batchFileCount: 1, batchBytes: bytes.count
            ),
            result: ChunkUploadBeginResult.self
        )
        let split = 7
        let first = bytes.prefix(split)
        let second = bytes.dropFirst(split)
        let firstResult = try await typedRPC(
            machine, id: "chunk-1", method: "file.upload.chunk",
            payload: ChunkUploadChunkRequest(uploadId: begin.uploadId, offset: 0, dataBase64: Data(first).base64EncodedString()),
            result: ChunkUploadChunkResult.self
        )
        expect(firstResult.nextOffset == split)
        let secondResult = try await typedRPC(
            machine, id: "chunk-2", method: "file.upload.chunk",
            payload: ChunkUploadChunkRequest(uploadId: begin.uploadId, offset: split, dataBase64: Data(second).base64EncodedString()),
            result: ChunkUploadChunkResult.self
        )
        expect(secondResult.receivedBytes == bytes.count)
        let committed = try await typedRPC(
            machine, id: "commit", method: "file.upload.commit",
            payload: ChunkUploadCommitRequest(uploadId: begin.uploadId),
            result: ChunkUploadCommitResult.self
        )
        expect(try Data(contentsOf: URL(fileURLWithPath: committed.path)) == bytes)
        expect(committed.sha256 == digest)

        let cancelled = try await typedRPC(
            machine, id: "cancel", method: "file.upload.cancel",
            payload: ChunkUploadCancelRequest(uploadId: UUID().uuidString),
            result: ChunkUploadCancelResult.self
        )
        expect(cancelled.cancelled)
        expect(await cmux.snapshot() == [])
    }

    func testCommittedImageUploadAppearsInOwnerArtifactScanOnly() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cmux = RecordingCMUXFacade()
        let uploadService = ChunkedFileUploadService(rootURL: directory)
        let artifactService = TerminalArtifactService(dispatchNative: { method, _ in
            switch method {
            case "mobile.terminal.artifact.scan":
                return .failure(code: "method_not_found")
            case "surface.read_text":
                return .success(.object(["text": .string("")]))
            case "surface.list":
                return .success(.object(["surfaces": .array([])]))
            default:
                return .failure(code: "method_not_found")
            }
        })
        let owner = WSProtocolMachine(
            cmux: cmux,
            authenticatedDeviceID: "owner-device",
            uploadService: uploadService,
            artifactService: artifactService
        )
        _ = await hello(owner)

        let image = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let digest = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        let begin = try await typedRPC(
            owner,
            id: "image-begin",
            method: RemoteRPCMethod.uploadBegin.rawValue,
            payload: ChunkUploadBeginRequest(
                batchId: UUID().uuidString,
                filename: "camera.png",
                mimeType: "image/png",
                bytes: image.count,
                sha256: digest,
                batchFileCount: 1,
                batchBytes: image.count
            ),
            result: ChunkUploadBeginResult.self
        )
        _ = try await typedRPC(
            owner,
            id: "image-chunk",
            method: RemoteRPCMethod.uploadChunk.rawValue,
            payload: ChunkUploadChunkRequest(
                uploadId: begin.uploadId,
                offset: 0,
                dataBase64: image.base64EncodedString()
            ),
            result: ChunkUploadChunkResult.self
        )
        let committed = try await typedRPC(
            owner,
            id: "image-commit",
            method: RemoteRPCMethod.uploadCommit.rawValue,
            payload: ChunkUploadCommitRequest(uploadId: begin.uploadId),
            result: ChunkUploadCommitResult.self
        )

        let ownerScan = try await typedRPC(
            owner,
            id: "owner-scan",
            method: RemoteRPCMethod.artifactScan.rawValue,
            payload: TerminalArtifactScanRequest(workspaceId: "workspace", surfaceId: "surface"),
            result: TerminalArtifactScanResult.self
        )
        let artifact = try XCTUnwrap(ownerScan.artifacts.first)
        XCTAssertEqual(artifact.filename, committed.filename)
        XCTAssertEqual(artifact.mimeType, "image/png")
        XCTAssertEqual(artifact.bytes, image.count)
        XCTAssertTrue(artifact.isImage)

        let fetched = try await typedRPC(
            owner,
            id: "owner-fetch",
            method: RemoteRPCMethod.artifactFetch.rawValue,
            payload: TerminalArtifactFetchRequest(artifactId: artifact.artifactId, offset: 0),
            result: TerminalArtifactFetchResult.self
        )
        XCTAssertEqual(try fetched.decodedBytes(), image)
        let thumbnail = try await typedRPC(
            owner,
            id: "owner-thumbnail",
            method: RemoteRPCMethod.artifactThumbnail.rawValue,
            payload: TerminalArtifactThumbnailRequest(artifactId: artifact.artifactId),
            result: TerminalArtifactThumbnailResult.self
        )
        XCTAssertFalse(try thumbnail.decodedBytes().isEmpty)

        let otherDevice = WSProtocolMachine(
            cmux: cmux,
            authenticatedDeviceID: "other-device",
            uploadService: uploadService,
            artifactService: artifactService
        )
        _ = await hello(otherDevice)
        let otherScan = try await typedRPC(
            otherDevice,
            id: "other-scan",
            method: RemoteRPCMethod.artifactScan.rawValue,
            payload: TerminalArtifactScanRequest(workspaceId: "workspace", surfaceId: "surface"),
            result: TerminalArtifactScanResult.self
        )
        XCTAssertTrue(otherScan.artifacts.isEmpty)
    }

    func testStableBatchIDEnforcesFileCountAcrossWebSocketReconnects() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cmux = RecordingCMUXFacade()
        let uploadService = ChunkedFileUploadService(rootURL: directory)
        let artifactService = inertArtifactService(cmux: cmux)
        let batchID = UUID().uuidString
        let emptyHash = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        var firstUploadID: String?

        for index in 0..<ChunkUploadLimits.maxBatchFiles {
            let machine = WSProtocolMachine(
                cmux: cmux,
                authenticatedDeviceID: "authenticated-device",
                uploadService: uploadService,
                artifactService: artifactService
            )
            _ = await hello(machine)
            let begin = try await typedRPC(
                machine,
                id: "begin-\(index)",
                method: "file.upload.begin",
                payload: ChunkUploadBeginRequest(
                    batchId: batchID,
                    filename: "reconnect-\(index).bin",
                    mimeType: "application/octet-stream",
                    bytes: 0,
                    sha256: emptyHash,
                    batchFileCount: ChunkUploadLimits.maxBatchFiles,
                    batchBytes: 0
                ),
                result: ChunkUploadBeginResult.self
            )
            expect(begin.batchId == batchID)
            if firstUploadID == nil { firstUploadID = begin.uploadId }
            _ = try await typedRPC(
                machine,
                id: "commit-\(index)",
                method: "file.upload.commit",
                payload: ChunkUploadCommitRequest(uploadId: begin.uploadId),
                result: ChunkUploadCommitResult.self
            )
        }

        let eleventh = WSProtocolMachine(
            cmux: cmux,
            authenticatedDeviceID: "authenticated-device",
            uploadService: uploadService,
            artifactService: artifactService
        )
        _ = await hello(eleventh)
        let overflowRequest = try RPCRequest(
            id: "eleventh",
            method: RemoteRPCMethod.uploadBegin.rawValue,
            payload: ChunkUploadBeginRequest(
                batchId: batchID,
                filename: "eleventh.bin",
                mimeType: "application/octet-stream",
                bytes: 0,
                sha256: emptyHash,
                batchFileCount: ChunkUploadLimits.maxBatchFiles,
                batchBytes: 0
            )
        )
        let overflow = try await rpc(
            eleventh,
            id: overflowRequest.id,
            method: overflowRequest.method,
            params: overflowRequest.params
        )
        expect(overflow.error?.code == "size_limit_exceeded")
        expect(overflow.error?.data == .object(["field": .string("batch_file_count")]))
        expect(try await rpc(eleventh, id: "battery-after-overflow", method: "host.battery", params: .object([:])).isOk)

        let conflictRequest = try RPCRequest(
            id: "conflict",
            method: RemoteRPCMethod.uploadBegin.rawValue,
            payload: ChunkUploadBeginRequest(
                batchId: batchID,
                filename: "conflict.bin",
                mimeType: "application/octet-stream",
                bytes: 0,
                sha256: emptyHash,
                batchFileCount: ChunkUploadLimits.maxBatchFiles - 1,
                batchBytes: 0
            )
        )
        let conflict = try await rpc(
            eleventh,
            id: conflictRequest.id,
            method: conflictRequest.method,
            params: conflictRequest.params
        )
        expect(conflict.error?.code == "upload_conflict")
        expect(conflict.error?.data == .object(["field": .string("batch_id")]))

        let otherDevice = WSProtocolMachine(
            cmux: cmux,
            authenticatedDeviceID: "other-device",
            uploadService: uploadService,
            artifactService: artifactService
        )
        _ = await hello(otherDevice)
        let otherBegin = try await typedRPC(
            otherDevice,
            id: "other-begin",
            method: "file.upload.begin",
            payload: ChunkUploadBeginRequest(
                batchId: batchID,
                filename: "other-device.bin",
                mimeType: "application/octet-stream",
                bytes: 0,
                sha256: emptyHash,
                batchFileCount: 1,
                batchBytes: 0
            ),
            result: ChunkUploadBeginResult.self
        )
        expect(otherBegin.batchId == batchID)
        let ownerUploadID = try require(firstUploadID)
        let spoofed = try await rpc(
            otherDevice,
            id: "spoof",
            method: "file.upload.commit",
            params: .object(["upload_id": .string(ownerUploadID)])
        )
        expect(spoofed.error?.code == "forbidden")
    }

    func testStableBatchIDRetainsAggregateBytesAcrossWebSocketReconnects() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cmux = RecordingCMUXFacade()
        let uploadService = ChunkedFileUploadService(rootURL: directory)
        let artifactService = inertArtifactService(cmux: cmux)
        let batchID = UUID().uuidString
        let emptyHash = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        let sizes = [100 * 1024 * 1024, 100 * 1024 * 1024, 50 * 1024 * 1024]
        var uploadIDs: [String] = []

        for (index, bytes) in sizes.enumerated() {
            let machine = WSProtocolMachine(
                cmux: cmux,
                authenticatedDeviceID: "authenticated-device",
                uploadService: uploadService,
                artifactService: artifactService
            )
            _ = await hello(machine)
            let begin = try await typedRPC(
                machine,
                id: "aggregate-\(index)",
                method: "file.upload.begin",
                payload: ChunkUploadBeginRequest(
                    batchId: batchID,
                    filename: "aggregate-\(index).bin",
                    mimeType: "application/octet-stream",
                    bytes: bytes,
                    sha256: emptyHash,
                    batchFileCount: 4,
                    batchBytes: ChunkUploadLimits.maxBatchBytes
                ),
                result: ChunkUploadBeginResult.self
            )
            uploadIDs.append(begin.uploadId)
        }

        let overflowMachine = WSProtocolMachine(
            cmux: cmux,
            authenticatedDeviceID: "authenticated-device",
            uploadService: uploadService,
            artifactService: artifactService
        )
        _ = await hello(overflowMachine)
        let overflowRequest = try RPCRequest(
            id: "aggregate-overflow",
            method: RemoteRPCMethod.uploadBegin.rawValue,
            payload: ChunkUploadBeginRequest(
                batchId: batchID,
                filename: "aggregate-overflow.bin",
                mimeType: "application/octet-stream",
                bytes: 1,
                sha256: emptyHash,
                batchFileCount: 4,
                batchBytes: ChunkUploadLimits.maxBatchBytes
            )
        )
        let overflow = try await rpc(
            overflowMachine,
            id: overflowRequest.id,
            method: overflowRequest.method,
            params: overflowRequest.params
        )
        expect(overflow.error?.code == "size_limit_exceeded")
        expect(overflow.error?.data == .object(["field": .string("batch_bytes")]))
        expect(try await rpc(overflowMachine, id: "battery-after-bytes", method: "host.battery", params: .object([:])).isOk)

        for uploadID in uploadIDs {
            _ = try await typedRPC(
                overflowMachine,
                id: "cancel-\(uploadID)",
                method: "file.upload.cancel",
                payload: ChunkUploadCancelRequest(uploadId: uploadID),
                result: ChunkUploadCancelResult.self
            )
        }
    }

    func testMalformedUploadRequestsReturnTypedErrorsAndSocketRemainsLive() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cmux = RecordingCMUXFacade()
        let machine = WSProtocolMachine(
            cmux: cmux,
            authenticatedDeviceID: "authenticated-device",
            uploadService: ChunkedFileUploadService(rootURL: directory),
            artifactService: inertArtifactService(cmux: cmux)
        )
        _ = await hello(machine)

        let malformedCases: [(JSONValue, String, String)] = [
            (
                .object(["upload_id": .string(UUID().uuidString), "offset": .int(0), "data_base64": .string("%%%")]),
                "invalid_base64",
                "data_base64"
            ),
            (
                .object(["upload_id": .string(UUID().uuidString), "offset": .int(-1), "data_base64": .string("YQ==")]),
                "invalid_offset",
                "offset"
            ),
        ]
        for (index, malformedCase) in malformedCases.enumerated() {
            let malformed = try await rpc(
                machine,
                id: "bad-\(index)",
                method: "file.upload.chunk",
                params: malformedCase.0
            )
            expect(!malformed.isOk)
            expect(malformed.error?.code == malformedCase.1)
            expect(malformed.error?.data == .object(["field": .string(malformedCase.2)]))
            let battery = try await rpc(machine, id: "battery-\(index)", method: "host.battery", params: .object([:]))
            expect(battery.isOk)
        }
        expect(await cmux.snapshot() == [])
    }

    func testArtifactFetchFramesStayUnderOneMiBAndReachEOFLikeShippedApps() async throws {
        let cmux = RecordingCMUXFacade()
        let fixture = Data((0..<(2 * 1_024 * 1_024)).map { UInt8($0 % 251) })
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = WSProtocolMachine(
            cmux: cmux,
            authenticatedDeviceID: "owner-device",
            uploadService: ChunkedFileUploadService(rootURL: directory),
            artifactService: makeArtifactService(cmux: cmux, bytes: fixture)
        )
        _ = await hello(machine)
        let scan = try await typedRPC(
            machine, id: "scan", method: "terminal.artifact.scan",
            payload: TerminalArtifactScanRequest(workspaceId: "workspace", surfaceId: "surface"),
            result: TerminalArtifactScanResult.self
        )
        let artifact = try require(scan.artifacts.first)

        var received = Data()
        var sizes: [Int] = []
        var offset = 0
        while sizes.count < 8 {
            let request = try RPCRequest(
                id: "fetch-\(offset)", method: RemoteRPCMethod.artifactFetch.rawValue,
                payload: TerminalArtifactFetchRequest(artifactId: artifact.artifactId, offset: offset)
            )
            let actions = await machine.processText(try require(String(data: JSONEncoder().encode(request), encoding: .utf8)))
            guard actions.count == 1, case .sendText(let responseText) = actions[0] else {
                return XCTFail("expected one fetch response")
            }
            XCTAssertLessThan(try WebSocketFramedSize(text: responseText).totalBytes, 1_048_576)
            let chunk = try JSONDecoder().decode(RPCResponse.self, from: Data(responseText.utf8))
                .decodeResult(TerminalArtifactFetchResult.self)
            let data = try chunk.decodedBytes()
            let next = offset + data.count
            XCTAssertEqual(chunk.artifactId, artifact.artifactId)
            XCTAssertEqual(chunk.offset, offset)
            XCTAssertEqual(chunk.totalBytes, fixture.count)
            XCTAssertTrue(chunk.eof || !data.isEmpty)
            XCTAssertEqual(chunk.eof, next == fixture.count)
            received.append(data)
            sizes.append(data.count)
            offset = next
            if chunk.eof { break }
        }

        XCTAssertEqual(sizes, [737_280, 737_280, 622_592])
        XCTAssertEqual(received, fixture)
    }

    func testArtifactMethodsUseAuthenticatedIdentityAndRemainLiveAfterUnauthorizedRequest() async throws {
        let cmux = RecordingCMUXFacade()
        let fixture = Data("artifact bytes".utf8)
        let artifactService = makeArtifactService(cmux: cmux, bytes: fixture)
        let ownerDirectory = try temporaryDirectory()
        let intruderDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: ownerDirectory)
            try? FileManager.default.removeItem(at: intruderDirectory)
        }
        let owner = WSProtocolMachine(
            cmux: cmux,
            authenticatedDeviceID: "owner-device",
            uploadService: ChunkedFileUploadService(rootURL: ownerDirectory),
            artifactService: artifactService
        )
        _ = await hello(owner)

        let scan = try await typedRPC(
            owner, id: "scan", method: "terminal.artifact.scan",
            payload: TerminalArtifactScanRequest(workspaceId: "workspace", surfaceId: "surface"),
            result: TerminalArtifactScanResult.self
        )
        let artifact = try require(scan.artifacts.first)
        expect(artifact.filename == "fixture.png")
        expect(artifact.isImage)

        let stat = try await typedRPC(
            owner, id: "stat", method: "terminal.artifact.stat",
            payload: TerminalArtifactStatRequest(artifactId: artifact.artifactId),
            result: TerminalArtifactStatResult.self
        )
        expect(stat.bytes == fixture.count)
        let fetched = try await typedRPC(
            owner, id: "fetch", method: "terminal.artifact.fetch",
            payload: TerminalArtifactFetchRequest(artifactId: artifact.artifactId, offset: 0),
            result: TerminalArtifactFetchResult.self
        )
        expect(try fetched.decodedBytes() == fixture)
        let thumbnail = try await typedRPC(
            owner, id: "thumbnail", method: "terminal.artifact.thumbnail",
            payload: TerminalArtifactThumbnailRequest(artifactId: artifact.artifactId),
            result: TerminalArtifactThumbnailResult.self
        )
        expect(thumbnail.mimeType == "image/jpeg")

        let intruder = WSProtocolMachine(
            cmux: cmux,
            authenticatedDeviceID: "other-device",
            uploadService: ChunkedFileUploadService(rootURL: intruderDirectory),
            artifactService: artifactService
        )
        _ = await hello(intruder)
        let denied = try await rpc(
            intruder, id: "denied", method: "terminal.artifact.stat",
            params: .object(["artifact_id": .string(artifact.artifactId)])
        )
        expect(denied.error?.code == "forbidden")
        expect(denied.error?.data == .object(["field": .string("artifact_id")]))
        expect(try await rpc(intruder, id: "battery", method: "host.battery", params: .object([:])).isOk)
    }

    private func hello(_ machine: WSProtocolMachine) async -> [WSProtocolMachine.Action] {
        await machine.processText(#"{"deviceId":"hello-device","appVersion":"1","protocolVersion":1}"#)
    }

    private func rpc(
        _ machine: WSProtocolMachine,
        id: String,
        method: String,
        params: JSONValue
    ) async throws -> RPCResponse {
        let request = RPCRequest(id: id, method: method, params: params)
        let text = try require(String(data: JSONEncoder().encode(request), encoding: .utf8))
        let actions = await machine.processText(text)
        expect(actions.count == 1)
        guard case .sendText(let responseText) = try require(actions.first) else {
            throw TestFailure.unexpectedAction
        }
        return try JSONDecoder().decode(RPCResponse.self, from: Data(responseText.utf8))
    }

    private func typedRPC<Request: Encodable, Result: Decodable>(
        _ machine: WSProtocolMachine,
        id: String,
        method: String,
        payload: Request,
        result: Result.Type
    ) async throws -> Result {
        let request = try RPCRequest(id: id, method: method, payload: payload)
        let response = try await rpc(machine, id: request.id, method: request.method, params: request.params)
        return try response.decodeResult(result)
    }

    private func temporaryDirectory() throws -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        guard let resolved = temporaryPath.withCString({ Darwin.realpath($0, nil) }) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { Darwin.free(resolved) }
        let url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("cmux-ws-protocol-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func browserMachine(directory: URL, cmux: FakeBrowserCMUX) -> WSProtocolMachine {
        let facade = RecordingCMUXFacade()
        return WSProtocolMachine(
            cmux: facade,
            authenticatedDeviceID: "browser-device",
            uploadService: ChunkedFileUploadService(rootURL: directory),
            artifactService: inertArtifactService(cmux: facade),
            browserCaptureService: BrowserCaptureService(
                dispatch: cmux.dispatch,
                clock: { Date(timeIntervalSince1970: 1_794_240_000) }
            )
        )
    }

    private func feedMachine(directory: URL, cmux: FakeFeedCMUX) -> WSProtocolMachine {
        let facade = RecordingCMUXFacade()
        return WSProtocolMachine(
            cmux: facade,
            authenticatedDeviceID: "feed-device",
            uploadService: ChunkedFileUploadService(rootURL: directory),
            artifactService: inertArtifactService(cmux: facade),
            feedService: FeedService(dispatch: cmux.dispatch)
        )
    }

    private func claudeMachine(directory: URL, vault: FakeVaultCMUX, root: String) -> WSProtocolMachine {
        let facade = RecordingCMUXFacade()
        return WSProtocolMachine(
            cmux: facade,
            authenticatedDeviceID: "claude-device",
            uploadService: ChunkedFileUploadService(rootURL: directory),
            artifactService: inertArtifactService(cmux: facade),
            claudeTranscriptService: ClaudeTranscriptService(dispatch: vault.dispatch, root: root, log: { _ in })
        )
    }

    private func printClaudeWireSample<Frame: Encodable>(_ label: String, _ frame: Frame) throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(frame))
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        print("CLAUDE_WIRE_SAMPLE \(label) \(String(decoding: data, as: UTF8.self))")
    }

    /// Prints a wire sample for APP-CONTRACT-NOTES.
    private func printFeedWireSample<Frame: Encodable>(_ label: String, _ frame: Frame) throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(frame))
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        print("FEED_WIRE_SAMPLE \(label) \(String(decoding: data, as: UTF8.self))")
    }

    /// Prints a wire sample for APP-CONTRACT-NOTES with the JPEG body replaced by its length.
    private func printBrowserWireSample<Frame: Encodable>(_ label: String, _ frame: Frame) throws {
        var object = try require(JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as? [String: Any])
        if var result = object["result"] as? [String: Any], let image = result["image_base64"] as? String {
            result["image_base64"] = "<\(image.count) base64 chars>"
            object["result"] = result
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print("BROWSER_CAPTURE_WIRE_SAMPLE \(label) \(String(decoding: data, as: UTF8.self))")
    }

    private func documentArtifactService(surfaces: [String: JSONValue]) -> TerminalArtifactService {
        let entries: [JSONValue] = surfaces.keys.sorted().map { id in
            guard case .object(var fields) = surfaces[id] else { return .null }
            fields["surface_id"] = .string(id)
            return .object(fields)
        }
        let listing = JSONValue.object([
            "workspaces": .array([.object(["id": .string("W"), "surfaces": .array(entries)])]),
        ])
        return TerminalArtifactService(dispatchNative: { method, _ in
            method == "mobile.workspace.list" ? .success(listing) : .failure(code: "method_not_found")
        })
    }

    private func inertArtifactService(cmux: any CMUXFacade) -> TerminalArtifactService {
        TerminalArtifactService(dispatchNative: { method, params in
            do { return .success(try await cmux.dispatch(method: method, params: params)) }
            catch { return .failure(code: "internal_error") }
        })
    }

    private func makeArtifactService(cmux: any CMUXFacade, bytes: Data) -> TerminalArtifactService {
        let identity = ArtifactAuthorizationStore.FileIdentity(
            device: 1, inode: 2, size: Int64(bytes.count), modifiedSeconds: 3,
            modifiedNanoseconds: 4, revision: "revision-1"
        )
        let fileSystem = TerminalArtifactService.FileSystem(
            inspect: { _, _ in
                .init(
                    canonicalPath: "/tmp/fixture.png", displayName: "fixture.png", kind: "image",
                    mimeType: "image/png", identity: identity
                )
            },
            read: { _, _, offset, length in
                let start = Int(offset)
                return Data(bytes[start..<min(bytes.count, start + length)])
            },
            thumbnail: { _, _, _ in (Data([0xFF, 0xD8, 0xFF, 0xD9]), 1, 1) }
        )
        return TerminalArtifactService(
            dispatchNative: { method, params in
                switch method {
                case "mobile.terminal.artifact.scan": return .failure(code: "method_not_found")
                case "surface.read_text": return .success(.object(["text": .string("/tmp/fixture.png")]))
                case "surface.list": return .success(.object(["surfaces": .array([])]))
                default:
                    do { return .success(try await cmux.dispatch(method: method, params: params)) }
                    catch { return .failure(code: "internal_error") }
                }
            },
            fileSystem: fileSystem,
            makeID: { "artifact-id" }
        )
    }

    private func expect(
        _ condition: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(condition, file: file, line: line)
    }

    private func require<Value>(
        _ value: Value?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Value {
        try XCTUnwrap(value, file: file, line: line)
    }

}

private enum TestFailure: Error {
    case unexpectedAction
}

// MARK: - Test doubles

final class NoOpCMUXFacade: CMUXFacade {
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        .object([:])
    }
}

actor RecordingCMUXFacade: CMUXFacade {
    struct Call: Equatable, Sendable { let method: String }
    private var calls: [Call] = []
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        calls.append(.init(method: method))
        return .object([:])
    }
    func snapshot() -> [Call] { calls }
}

actor ParamsRecordingCMUXFacade: CMUXFacade {
    struct Call: Equatable, Sendable { let method: String; let params: JSONValue }
    private var calls: [Call] = []
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        calls.append(.init(method: method, params: params))
        return .object([:])
    }
    func snapshot() -> [Call] { calls }
}

final class RateLimitedCMUXFacade: CMUXFacade {
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        throw RPCError(code: "rate_limited", message: "Polling rate limited for this connection",
                       data: .object(["retry_after_ms": .int(40)]))
    }
}

final class ThrowingCMUXFacade: CMUXFacade {
    struct Boom: Error {}
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        throw Boom()
    }
}
