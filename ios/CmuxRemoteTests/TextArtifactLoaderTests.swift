import Foundation
import SharedKit
import Testing
@testable import CmuxRemote

@Suite("TextArtifactLoaderTests", .timeLimit(.minutes(1)))
struct TextArtifactLoaderTests {
    private let fetch = RemoteRPCMethod.artifactFetch.rawValue

    @Test
    func testConcatenatesChunksInOrder() async throws {
        let rpc = DocumentRPCStub()
        let first = Data("Hello, ".utf8)
        let second = Data("world".utf8)
        let total = first.count + second.count
        await rpc.enqueue(.response(DocumentFixtures.fetchResponse(offset: 0, total: total, data: first, eof: false)), for: fetch)
        await rpc.enqueue(.response(DocumentFixtures.fetchResponse(offset: first.count, total: total, data: second, eof: true)), for: fetch)

        let document = try await TextArtifactLoader(rpc: rpc).load(DocumentFixtures.artifact(bytes: total))

        #expect(document.text == "Hello, world")
        #expect(!document.isTruncated)
        let offsets = await rpc.params(method: fetch).map { params -> Int64? in
            if case .object(let object) = params, case .int(let offset)? = object["offset"] { return offset }
            return nil
        }
        #expect(offsets == [0, Int64(first.count)])
    }

    @Test
    func testInvalidUTF8BecomesReplacementCharacter() async throws {
        let rpc = DocumentRPCStub()
        let bytes = Data([0x61, 0xFF, 0x62])
        await rpc.enqueue(.response(DocumentFixtures.fetchResponse(offset: 0, total: bytes.count, data: bytes, eof: true)), for: fetch)

        let document = try await TextArtifactLoader(rpc: rpc).load(DocumentFixtures.artifact(bytes: bytes.count))

        #expect(document.text == "a\u{FFFD}b")
    }

    @Test
    func testTruncatesAtDisplayLimitOnScalarBoundary() async throws {
        let rpc = DocumentRPCStub()
        let bytes = Data("abcd한".utf8)
        await rpc.enqueue(.response(DocumentFixtures.fetchResponse(offset: 0, total: bytes.count, data: bytes, eof: true)), for: fetch)

        let document = try await TextArtifactLoader(rpc: rpc, displayLimit: 5).load(DocumentFixtures.artifact(bytes: bytes.count))

        #expect(document.text == "abcd")
        #expect(document.isTruncated)
        #expect(document.displayedBytes == 4)
        #expect(document.totalBytes == bytes.count)
    }

    @Test
    func testStopsFetchingOnceLimitReached() async throws {
        let rpc = DocumentRPCStub()
        let firstChunk = Data("abcdef".utf8)
        await rpc.enqueue(.response(DocumentFixtures.fetchResponse(offset: 0, total: 10, data: firstChunk, eof: false)), for: fetch)

        let document = try await TextArtifactLoader(rpc: rpc, displayLimit: 4).load(DocumentFixtures.artifact(bytes: 10))

        #expect(document.text == "abcd")
        #expect(document.isTruncated)
        #expect(await rpc.callCount(method: fetch) == 1)
    }

    /// The relay sends at most 720 KiB per fetch so one frame stays under 1 MiB.
    private static let relayChunkBytes = 737_280

    private func fetchOffsets(_ rpc: DocumentRPCStub) async -> [Int64?] {
        await rpc.params(method: fetch).map { params -> Int64? in
            if case .object(let object) = params, case .int(let offset)? = object["offset"] { return offset }
            return nil
        }
    }

    /// Enqueues `total` bytes as consecutive relay-budget chunks, all of `body`.
    private func enqueueRelayChunks(_ body: Data, total: Int, into rpc: DocumentRPCStub, count: Int) async {
        var offset = 0
        for _ in 0..<count {
            let size = min(Self.relayChunkBytes, total - offset)
            let chunk = body.subdata(in: offset..<(offset + size))
            let eof = offset + size == total
            await rpc.enqueue(.response(DocumentFixtures.fetchResponse(offset: offset, total: total, data: chunk, eof: eof)), for: fetch)
            offset += size
        }
    }

    @Test
    func testJoinsRelayBudgetChunksUpToDisplayLimit() async throws {
        let rpc = DocumentRPCStub()
        let total = 3 * 1024 * 1024
        let body = Data(repeating: UInt8(ascii: "a"), count: total)
        await enqueueRelayChunks(body, total: total, into: rpc, count: 3)

        let document = try await TextArtifactLoader(rpc: rpc).load(DocumentFixtures.artifact(bytes: total))

        #expect(document.displayedBytes == TextArtifactLoader.displayLimitBytes)
        #expect(document.isTruncated)
        #expect(document.totalBytes == total)
        #expect(await rpc.callCount(method: fetch) == 3)
        #expect(await fetchOffsets(rpc) == [0, 737_280, 1_474_560])
    }

    @Test
    func testDocumentUnderDisplayLimitAcrossChunksIsNotTruncated() async throws {
        let rpc = DocumentRPCStub()
        let total = 2 * Self.relayChunkBytes + 102_400
        let body = Data((0..<total).map { UInt8(ascii: "a") + UInt8($0 % 26) })
        await enqueueRelayChunks(body, total: total, into: rpc, count: 3)

        let document = try await TextArtifactLoader(rpc: rpc).load(DocumentFixtures.artifact(bytes: total))

        #expect(!document.isTruncated)
        #expect(document.rawPrefix == body)
        #expect(await fetchOffsets(rpc) == [0, 737_280, 1_474_560])
    }

    @Test
    func testExactlyDisplayLimitAcrossChunksIsNotTruncated() async throws {
        let rpc = DocumentRPCStub()
        let total = TextArtifactLoader.displayLimitBytes
        let body = Data(repeating: UInt8(ascii: "b"), count: total)
        await enqueueRelayChunks(body, total: total, into: rpc, count: 3)

        let document = try await TextArtifactLoader(rpc: rpc).load(DocumentFixtures.artifact(bytes: total))

        #expect(!document.isTruncated)
        #expect(document.displayedBytes == total)
        #expect(await rpc.callCount(method: fetch) == 3)
    }

    @Test
    func testCancellationBetweenChunksRequestsNoNextChunk() async throws {
        let rpc = DocumentRPCStub()
        let total = 3 * Self.relayChunkBytes
        let body = Data(repeating: UInt8(ascii: "c"), count: total)
        await rpc.enqueue(.response(DocumentFixtures.fetchResponse(
            offset: 0, total: total, data: body.prefix(Self.relayChunkBytes), eof: false
        )), for: fetch)
        await rpc.enqueue(.gate("second"), for: fetch)

        let loading = Task { try await TextArtifactLoader(rpc: rpc).load(DocumentFixtures.artifact(bytes: total)) }
        await rpc.waitUntilReached("second")
        loading.cancel()
        await rpc.release("second", with: DocumentFixtures.fetchResponse(
            offset: Self.relayChunkBytes,
            total: total,
            data: body.subdata(in: Self.relayChunkBytes..<(2 * Self.relayChunkBytes)),
            eof: false
        ))

        await #expect(throws: CancellationError.self) { _ = try await loading.value }
        #expect(await rpc.callCount(method: fetch) == 2)
    }

    @Test
    func testDefaultDisplayLimitIsTwoMebibytes() {
        #expect(TextArtifactLoader.displayLimitBytes == 2 * 1024 * 1024)
    }

    @Test
    func testRejectsOffsetOrRevisionMismatch() async throws {
        let bytes = Data("abc".utf8)
        let offsetRPC = DocumentRPCStub()
        await offsetRPC.enqueue(.response(DocumentFixtures.fetchResponse(offset: 1, total: bytes.count, data: bytes, eof: true)), for: fetch)
        await #expect(throws: TextArtifactLoaderError.malformedChunk) {
            _ = try await TextArtifactLoader(rpc: offsetRPC).load(DocumentFixtures.artifact(bytes: bytes.count))
        }

        let revisionRPC = DocumentRPCStub()
        await revisionRPC.enqueue(.response(DocumentFixtures.fetchResponse(offset: 0, total: bytes.count, revision: "r2", data: bytes, eof: true)), for: fetch)
        await #expect(throws: TextArtifactLoaderError.fileChanged) {
            _ = try await TextArtifactLoader(rpc: revisionRPC).load(DocumentFixtures.artifact(bytes: bytes.count))
        }
    }

    @Test
    func testPropagatesFileChangedRPCError() async throws {
        let rpc = DocumentRPCStub()
        await rpc.enqueue(.response(DocumentFixtures.error("file_changed")), for: fetch)

        do {
            _ = try await TextArtifactLoader(rpc: rpc).load(DocumentFixtures.artifact(bytes: 3))
            Issue.record("Expected file_changed to be thrown")
        } catch {
            #expect(error as? CmuxRemoteRPCError == .rpc(code: "file_changed", message: "file_changed"))
            #expect(DocumentLoadFailure(error: error) == .fileChanged)
        }
    }
}
