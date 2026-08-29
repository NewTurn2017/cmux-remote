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

        expect(capabilities.capabilities == ["file.upload.v2", "terminal.artifact.v1"])
        expect(await cmux.snapshot() == [])
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

final class ThrowingCMUXFacade: CMUXFacade {
    struct Boom: Error {}
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        throw Boom()
    }
}
