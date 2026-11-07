import Foundation
import SharedKit
import Testing
@testable import RelayServer

@Suite("BoundedRelayWorkTests")
struct BoundedRelayWorkTests {
    @Test func returnsFinishedWorkBeforeTheDeadline() async {
        let outcome = await BoundedRelayWork.run(timeout: .seconds(5)) { 42 }

        guard case .finished(let value) = outcome else {
            Issue.record("fast work must finish")
            return
        }
        #expect(value == 42)
    }

    @Test func answersAtTheDeadlineWhenWorkNeverReturns() async {
        let blocker = AsyncStream<Void>.makeStream()
        defer { blocker.continuation.finish() }

        let outcome = await BoundedRelayWork.run(timeout: .milliseconds(50)) {
            for await _ in blocker.stream {}
            return 1
        }

        guard case .timedOut = outcome else {
            Issue.record("blocked work must time out")
            return
        }
    }

    /// A relay-owned file RPC that never returns, as when `~/Downloads` waits on a macOS
    /// privacy prompt, must not hold the WebSocket FIFO: it answers with
    /// `temporarily_unavailable` and the next frame still runs.
    @Test func blockedArtifactScanAnswersAndLaterFramesStillRun() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-relay-work-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = AsyncStream<Void>.makeStream()
        defer { blocker.continuation.finish() }
        let artifactService = TerminalArtifactService(dispatchNative: { _, _ in
            for await _ in blocker.stream {}
            return .failure(code: "method_not_found")
        })
        let machine = WSProtocolMachine(
            cmux: RecordingCMUXFacade(),
            authenticatedDeviceID: "device",
            uploadService: ChunkedFileUploadService(rootURL: directory),
            artifactService: artifactService,
            relayOwnedTimeout: .milliseconds(100)
        )
        _ = await machine.processText(#"{"deviceId":"device","appVersion":"1.1.4","protocolVersion":1}"#)

        let scan = try Self.response(await machine.processText(
            #"{"id":"scan","method":"terminal.artifact.scan","params":{"workspace_id":"w","surface_id":"s"}}"#
        ))
        #expect(scan.id == "scan")
        #expect(scan.ok == false)
        #expect(scan.error?.code == WSProtocolMachine.temporarilyUnavailableCode)

        let battery = try Self.response(await machine.processText(
            #"{"id":"battery","method":"host.battery","params":{}}"#
        ))
        #expect(battery.id == "battery")
        #expect(battery.ok == true)
    }

    private static func response(_ actions: [WSProtocolMachine.Action]) throws -> RPCResponse {
        guard actions.count == 1, case .sendText(let text) = actions[0] else {
            throw ResponseShapeError()
        }
        return try JSONDecoder().decode(RPCResponse.self, from: Data(text.utf8))
    }

    private struct ResponseShapeError: Error {}
}
