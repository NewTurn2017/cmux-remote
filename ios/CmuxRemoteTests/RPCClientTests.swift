import XCTest
import Foundation
import SharedKit
@testable import CmuxRemote

final class RPCClientTests: XCTestCase {
    func testCallReturnsOnMatchingId() async throws {
        let transport = RecordingRPCTransport()
        let rpc = RPCClient(transport: transport)
        var messages = await transport.messages().makeAsyncIterator()

        async let result = rpc.call(method: "workspace.list", params: .object([:]))
        let requestValue = await messages.next()
        let request = try XCTUnwrap(requestValue)
        let envelope = try JSONDecoder().decode(RPCRequest.self, from: Data(request.utf8))
        XCTAssertEqual(envelope.method, "workspace.list")

        await rpc.handleIncoming(text: #"{"id":"\#(envelope.id)","result":{"workspaces":[]}}"#)
        let response = try await result
        XCTAssertTrue(response.isOk)
    }

    func testPushFrameDispatchedToHandler() async {
        let counter = PushCounter()
        let rpc = RPCClient(transport: RecordingRPCTransport())
        await rpc.onPush { _ in
            Task { await counter.increment() }
        }
        var increments = await counter.increments().makeAsyncIterator()

        await rpc.handleIncoming(text: #"{"type":"event","category":"system","name":"x","payload":{}}"#)

        _ = await increments.next()
        let value = await counter.value
        XCTAssertEqual(value, 1)
    }

    func testCallTimesOutWithoutResponse() async {
        let rpc = RPCClient(transport: RecordingRPCTransport(), timeoutNanoseconds: 1_000_000)
        do {
            _ = try await rpc.call(method: "workspace.list", params: .object([:]))
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? RPCClientError, .timeout)
        }
    }

    func testCancelledUploadChunkCallRemovesPendingContinuationAndIgnoresLateResponse() async throws {
        try await assertCancelledFileCallRemovesPendingContinuationAndIgnoresLateResponse(
            method: RemoteRPCMethod.uploadChunk.rawValue
        )
    }

    func testCancelledArtifactFetchCallRemovesPendingContinuationAndIgnoresLateResponse() async throws {
        try await assertCancelledFileCallRemovesPendingContinuationAndIgnoresLateResponse(
            method: RemoteRPCMethod.artifactFetch.rawValue
        )
    }

    private func assertCancelledFileCallRemovesPendingContinuationAndIgnoresLateResponse(
        method: String
    ) async throws {
        let transport = RecordingRPCTransport()
        let rpc = RPCClient(transport: transport)
        var messages = await transport.messages().makeAsyncIterator()
        let cancelledCall = Task {
            try await rpc.call(method: method, params: .object([:]))
        }
        let cancelledRequestValue = await messages.next()
        let cancelledRequestText = try XCTUnwrap(cancelledRequestValue)
        let cancelledRequest = try JSONDecoder().decode(
            RPCRequest.self,
            from: Data(cancelledRequestText.utf8)
        )

        cancelledCall.cancel()
        do {
            _ = try await cancelledCall.value
            XCTFail("a cancelled RPC call must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        async let liveResponse = rpc.call(method: "host.capabilities", params: .object([:]))
        let liveRequestValue = await messages.next()
        let liveRequestText = try XCTUnwrap(liveRequestValue)
        let liveRequest = try JSONDecoder().decode(
            RPCRequest.self,
            from: Data(liveRequestText.utf8)
        )
        await rpc.handleIncoming(text: #"{"id":"\#(cancelledRequest.id)","result":{"ignored":true}}"#)
        await rpc.handleIncoming(text: #"{"id":"\#(liveRequest.id)","result":{"capabilities":[]}}"#)

        let response = try await liveResponse
        XCTAssertEqual(response.id, liveRequest.id)
    }
}

private actor RecordingRPCTransport: RPCTransport {
    private var outbox: [String] = []
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: String.self)
    }

    func messages() -> AsyncStream<String> {
        stream
    }

    func send(text: String) {
        outbox.append(text)
        continuation.yield(text)
    }

    func close() {}
}

private actor PushCounter {
    private(set) var value = 0
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func increments() -> AsyncStream<Void> {
        stream
    }

    func increment() {
        value += 1
        continuation.yield(())
    }
}
