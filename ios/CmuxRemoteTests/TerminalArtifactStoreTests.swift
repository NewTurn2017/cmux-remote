import Foundation
import SharedKit
import Testing
@testable import CmuxRemote

@Suite("TerminalArtifactStoreTests", .serialized, .timeLimit(.minutes(1)))
struct TerminalArtifactStoreTests {
    @Test @MainActor
    func testScanPublishesOrderedArtifactsWithoutChangingTerminalState() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        await fixture.rpc.enqueue(.response(Self.scanResponse(revision: "r1", includeDocument: true)), for: "terminal.artifact.scan")
        let store = fixture.makeStore()
        let surface = SurfaceStore(rpc: fixture.rpc)
        surface.grid.replaceRow(0, raw: "terminal remains here")
        surface.rev = 41
        surface.inputStatus = .sent("unchanged")

        await store.activate(identity: Self.identity(surfaceID: "surface-a"))

        #expect(store.state == .ready)
        #expect(store.scanGeneration == 3)
        #expect(store.artifacts.map(\.filename) == ["photo.png", "notes.pdf"])
        #expect(store.selection == nil)
        #expect(surface.grid.rawRows[0] == "terminal remains here")
        #expect(surface.rev == 41)
        #expect(surface.inputStatus == .sent("unchanged"))
        let calls = await fixture.rpc.recordedCalls(method: "terminal.artifact.scan")
        #expect(calls.count == 1)
        #expect(calls.first?.params == .object([
            "workspace_id": .string("workspace"),
            "surface_id": .string("surface-a"),
        ]))
    }

    @Test("testSurfaceSwitchIgnoresLateResponse") @MainActor
    func testSurfaceSwitchIgnoresLateResponse() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        await fixture.rpc.enqueue(.gate("old-scan"), for: "terminal.artifact.scan")
        await fixture.rpc.enqueue(.gate("new-scan"), for: "terminal.artifact.scan")
        let oldCall = await fixture.rpc.expectCall(method: "terminal.artifact.scan")
        let newCall = await fixture.rpc.expectCall(method: "terminal.artifact.scan")
        let store = fixture.makeStore()
        let surface = SurfaceStore(rpc: fixture.rpc)
        surface.grid.replaceRow(0, raw: "stable")
        surface.rev = 9
        surface.inputStatus = .idle

        let oldActivation = Task { await store.activate(identity: Self.identity(surfaceID: "old")) }
        _ = await oldCall.value()
        let newActivation = Task { await store.activate(identity: Self.identity(surfaceID: "new")) }
        _ = await newCall.value()

        await fixture.rpc.resolve("new-scan", with: Self.scanResponse(revision: "new", filename: "new.png"))
        await newActivation.value
        await oldActivation.value
        #expect(store.retiredOperationCount == 1)
        let drain = Task { await store.waitForRetiredOperationsToDrain() }
        await fixture.rpc.resolve("old-scan", with: Self.scanResponse(revision: "old", filename: "old.png"))
        await drain.value

        #expect(store.retiredOperationCount == 0)
        #expect(store.identity?.surfaceID == "new")
        #expect(store.artifacts.map(\.filename) == ["new.png"])
        #expect(store.artifacts.first?.revision == "new")
        #expect(surface.grid.rawRows[0] == "stable")
        #expect(surface.rev == 9)
        #expect(surface.inputStatus == .idle)
    }

    @Test @MainActor
    func testHostGenerationSwitchIgnoresLateResponse() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        await fixture.rpc.enqueue(.gate("old-host"), for: "terminal.artifact.scan")
        await fixture.rpc.enqueue(.gate("new-host"), for: "terminal.artifact.scan")
        let oldCall = await fixture.rpc.expectCall(method: "terminal.artifact.scan")
        let newCall = await fixture.rpc.expectCall(method: "terminal.artifact.scan")
        let store = fixture.makeStore()

        let oldActivation = Task { await store.activate(identity: Self.identity(hostGeneration: 7)) }
        _ = await oldCall.value()
        let newActivation = Task { await store.activate(identity: Self.identity(hostGeneration: 8)) }
        _ = await newCall.value()
        await fixture.rpc.resolve("new-host", with: Self.scanResponse(revision: "new-host"))
        await newActivation.value
        await fixture.rpc.resolve("old-host", with: Self.scanResponse(revision: "old-host"))
        await oldActivation.value

        #expect(store.identity?.hostGeneration == 8)
        #expect(store.artifacts.first?.revision == "new-host")
    }

    @Test("testMalformedSecondChunkDeletesPartial") @MainActor
    func testMalformedSecondChunkDeletesPartial() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let bytes = Data(Self.pngBytes.prefix(24))
        await fixture.rpc.enqueue(.response(Self.scanResponse(revision: "r1", bytes: Self.pngBytes.count)), for: "terminal.artifact.scan")
        await fixture.rpc.enqueue(.response(Self.statResponse(revision: "r1", bytes: Self.pngBytes.count, width: 1, height: 1)), for: "terminal.artifact.stat")
        await fixture.rpc.enqueue(.response(Self.fetchResponse(offset: 0, total: Self.pngBytes.count, revision: "r1", data: bytes, eof: false)), for: "terminal.artifact.fetch")
        await fixture.rpc.enqueue(.response(Self.fetchResponse(offset: bytes.count + 1, total: Self.pngBytes.count, revision: "r1", data: Self.pngBytes.dropFirst(bytes.count), eof: true)), for: "terminal.artifact.fetch")
        let store = fixture.makeStore()
        await store.activate(identity: Self.identity())
        let artifact = try #require(store.artifacts.first)

        await #expect(throws: TerminalArtifactStoreError.self) {
            _ = try await store.openViewer(for: artifact)
        }

        #expect(store.viewerURL == nil)
        #expect(store.selection == nil)
        #expect(await fixture.cache.partialFileCount() == 0)
        #expect(await fixture.cache.fullEntryCount() == 0)
        #expect(await fixture.rpc.callCount(method: "terminal.artifact.fetch") == 2)
    }

    @Test @MainActor
    func testRejectsMalformedFetchStreams() async throws {
        for malformed in MalformedFetchCase.allCases {
            let fixture = try StoreFixture()
            defer { fixture.cleanup() }
            let split = 20
            await fixture.rpc.enqueue(.response(Self.scanResponse(revision: "r1", bytes: Self.pngBytes.count)), for: "terminal.artifact.scan")
            await fixture.rpc.enqueue(.response(Self.statResponse(revision: "r1", bytes: Self.pngBytes.count, width: 1, height: 1)), for: "terminal.artifact.stat")
            await fixture.rpc.enqueue(.response(Self.fetchResponse(offset: 0, total: Self.pngBytes.count, revision: "r1", data: Self.pngBytes.prefix(split), eof: false)), for: "terminal.artifact.fetch")
            await fixture.rpc.enqueue(.response(Self.malformedResponse(malformed, offset: split)), for: "terminal.artifact.fetch")
            let store = fixture.makeStore()
            await store.activate(identity: Self.identity())
            let artifact = try #require(store.artifacts.first)

            await #expect(throws: TerminalArtifactStoreError.self) {
                _ = try await store.openViewer(for: artifact)
            }

            #expect(store.viewerURL == nil)
            #expect(await fixture.cache.partialFileCount() == 0)
            #expect(await fixture.cache.fullEntryCount() == 0)
            #expect(await fixture.rpc.callCount(method: "terminal.artifact.fetch") == 2)
        }
    }

    @Test @MainActor
    func testCancellationDeletesPartialAndRequestsNoNextChunk() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let split = 20
        await fixture.rpc.enqueue(.response(Self.scanResponse(revision: "r1", bytes: Self.pngBytes.count)), for: "terminal.artifact.scan")
        await fixture.rpc.enqueue(.response(Self.statResponse(revision: "r1", bytes: Self.pngBytes.count, width: 1, height: 1)), for: "terminal.artifact.stat")
        await fixture.rpc.enqueue(.gate("first-fetch"), for: "terminal.artifact.fetch")
        let fetchCall = await fixture.rpc.expectCall(method: "terminal.artifact.fetch")
        let store = fixture.makeStore()
        await store.activate(identity: Self.identity())
        let artifact = try #require(store.artifacts.first)

        let opening = Task { try await store.openViewer(for: artifact) }
        _ = await fetchCall.value()
        opening.cancel()
        await fixture.rpc.resolve("first-fetch", with: Self.fetchResponse(offset: 0, total: Self.pngBytes.count, revision: "r1", data: Self.pngBytes.prefix(split), eof: false))
        _ = try? await opening.value

        #expect(store.viewerURL == nil)
        #expect(await fixture.cache.partialFileCount() == 0)
        #expect(await fixture.rpc.callCount(method: "terminal.artifact.fetch") == 1)
    }

    @Test @MainActor
    func testDuplicateRequestsCoalesceAndRevisionChangeRefetches() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        await fixture.rpc.enqueue(.response(Self.scanResponse(revision: "r1", bytes: Self.pngBytes.count)), for: "terminal.artifact.scan")
        await fixture.rpc.enqueue(.gate("thumb-r1"), for: "terminal.artifact.thumbnail")
        await fixture.rpc.enqueue(.response(Self.statResponse(revision: "r1", bytes: Self.pngBytes.count, width: 1, height: 1)), for: "terminal.artifact.stat")
        await fixture.rpc.enqueue(.gate("fetch-r1"), for: "terminal.artifact.fetch")
        let thumbnailCall = await fixture.rpc.expectCall(method: "terminal.artifact.thumbnail")
        let fetchCall = await fixture.rpc.expectCall(method: "terminal.artifact.fetch")
        let store = fixture.makeStore()
        await store.activate(identity: Self.identity())
        let r1 = try #require(store.artifacts.first)

        let thumbnailA = Task { try await store.thumbnail(for: r1, dimension: 512) }
        let thumbnailB = Task { try await store.thumbnail(for: r1, dimension: 512) }
        _ = await thumbnailCall.value()
        await fixture.rpc.resolve("thumb-r1", with: Self.thumbnailResponse(revision: "r1"))
        #expect(try await thumbnailA.value == Self.pngBytes)
        #expect(try await thumbnailB.value == Self.pngBytes)
        #expect(await fixture.rpc.callCount(method: "terminal.artifact.thumbnail") == 1)

        let viewerA = Task { try await store.openViewer(for: r1) }
        let viewerB = Task { try await store.openViewer(for: r1) }
        _ = await fetchCall.value()
        await fixture.rpc.resolve("fetch-r1", with: Self.fetchResponse(offset: 0, total: Self.pngBytes.count, revision: "r1", data: Self.pngBytes, eof: true))
        let firstURL = try await viewerA.value
        _ = try await viewerB.value
        #expect(store.selection == "artifact")
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(await fixture.rpc.callCount(method: "terminal.artifact.fetch") == 1)

        await store.dismissViewer()
        #expect(store.selection == nil)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        _ = try await store.openViewer(for: r1)
        #expect(await fixture.rpc.callCount(method: "terminal.artifact.fetch") == 1)

        await fixture.rpc.enqueue(.response(Self.scanResponse(revision: "r2", bytes: Self.pngBytes.count)), for: "terminal.artifact.scan")
        await fixture.rpc.enqueue(.response(Self.statResponse(revision: "r2", bytes: Self.pngBytes.count, width: 1, height: 1)), for: "terminal.artifact.stat")
        await fixture.rpc.enqueue(.response(Self.fetchResponse(offset: 0, total: Self.pngBytes.count, revision: "r2", data: Self.pngBytes, eof: true)), for: "terminal.artifact.fetch")
        await store.activate(identity: Self.identity())
        let r2 = try #require(store.artifacts.first)
        _ = try await store.openViewer(for: r2)
        #expect(await fixture.rpc.callCount(method: "terminal.artifact.fetch") == 2)
        #expect(await fixture.cache.containsFullContent(for: fixture.fullKey(revision: "r1")) == false)
    }

    @Test @MainActor
    func oneCancelledThumbnailWaiterDoesNotCancelCoalescedPeer() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        await fixture.rpc.enqueue(.response(Self.scanResponse(revision: "r1")), for: "terminal.artifact.scan")
        await fixture.rpc.enqueue(.gate("thumbnail"), for: "terminal.artifact.thumbnail")
        let thumbnailCall = await fixture.rpc.expectCall(method: "terminal.artifact.thumbnail")
        let store = fixture.makeStore()
        await store.activate(identity: Self.identity())
        let artifact = try #require(store.artifacts.first)

        let cancelled = Task { try await store.thumbnail(for: artifact) }
        let surviving = Task { try await store.thumbnail(for: artifact) }
        _ = await thumbnailCall.value()
        cancelled.cancel()
        await fixture.rpc.resolve("thumbnail", with: Self.thumbnailResponse(revision: "r1"))

        _ = try? await cancelled.value
        #expect(try await surviving.value == Self.pngBytes)
        #expect(await fixture.rpc.callCount(method: "terminal.artifact.thumbnail") == 1)
    }

    @Test @MainActor
    func oneCancelledFullWaiterDoesNotCancelCoalescedPeer() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        await fixture.rpc.enqueue(.response(Self.scanResponse(revision: "r1", bytes: Self.pngBytes.count)), for: "terminal.artifact.scan")
        await fixture.rpc.enqueue(.response(Self.statResponse(revision: "r1", bytes: Self.pngBytes.count, width: 1, height: 1)), for: "terminal.artifact.stat")
        await fixture.rpc.enqueue(.gate("fetch"), for: "terminal.artifact.fetch")
        let fetchCall = await fixture.rpc.expectCall(method: "terminal.artifact.fetch")
        let store = fixture.makeStore()
        await store.activate(identity: Self.identity())
        let artifact = try #require(store.artifacts.first)

        let cancelled = Task { try await store.openViewer(for: artifact) }
        let surviving = Task { try await store.openViewer(for: artifact) }
        _ = await fetchCall.value()
        cancelled.cancel()
        await fixture.rpc.resolve("fetch", with: Self.fetchResponse(offset: 0, total: Self.pngBytes.count, revision: "r1", data: Self.pngBytes, eof: true))

        _ = try? await cancelled.value
        let viewer = try await surviving.value
        #expect(FileManager.default.fileExists(atPath: viewer.path))
        #expect(await fixture.rpc.callCount(method: "terminal.artifact.fetch") == 1)
    }

    @Test @MainActor
    func identitySwitchDuringSuspendedThumbnailPublicationEvictsStaleWrite() async throws {
        let metadata = SuspendingTerminalArtifactFileMetadata(extensionName: "thumb")
        let fixture = try StoreFixture(fileMetadata: metadata)
        defer { fixture.cleanup() }
        await fixture.rpc.enqueue(.response(Self.scanResponse(revision: "old")), for: "terminal.artifact.scan")
        await fixture.rpc.enqueue(.response(Self.thumbnailResponse(revision: "old")), for: "terminal.artifact.thumbnail")
        let publication = await metadata.expectSecure()
        let store = fixture.makeStore()
        await store.activate(identity: Self.identity(surfaceID: "old"))
        let artifact = try #require(store.artifacts.first)
        let key = fixture.thumbnailKey(revision: "old")

        let loading = Task { try await store.thumbnail(for: artifact) }
        await publication.value()
        await fixture.rpc.enqueue(.response(Self.scanResponse(revision: "new")), for: "terminal.artifact.scan")
        await store.activate(identity: Self.identity(surfaceID: "new"))
        _ = try? await loading.value
        #expect(store.retiredOperationCount == 1)
        #expect(await fixture.cache.partialFileCount() == 0)
        let drain = Task { await store.waitForRetiredOperationsToDrain() }
        await metadata.releaseSecure()
        await drain.value

        #expect(store.retiredOperationCount == 0)
        #expect(await fixture.cache.thumbnail(for: key) == nil)
        #expect(store.identity?.surfaceID == "new")
        #expect(store.selection == nil)
    }

    @Test @MainActor
    func identitySwitchDuringSuspendedFullPublicationEvictsStaleWrite() async throws {
        let metadata = SuspendingTerminalArtifactFileMetadata(extensionName: "artifact")
        let fixture = try StoreFixture(fileMetadata: metadata)
        defer { fixture.cleanup() }
        await fixture.rpc.enqueue(.response(Self.scanResponse(revision: "old", bytes: Self.pngBytes.count)), for: "terminal.artifact.scan")
        await fixture.rpc.enqueue(.response(Self.statResponse(revision: "old", bytes: Self.pngBytes.count, width: 1, height: 1)), for: "terminal.artifact.stat")
        await fixture.rpc.enqueue(.response(Self.fetchResponse(offset: 0, total: Self.pngBytes.count, revision: "old", data: Self.pngBytes, eof: true)), for: "terminal.artifact.fetch")
        let publication = await metadata.expectSecure()
        let store = fixture.makeStore()
        await store.activate(identity: Self.identity(surfaceID: "old"))
        let artifact = try #require(store.artifacts.first)
        let key = fixture.fullKey(revision: "old")

        let loading = Task { try await store.openViewer(for: artifact) }
        await publication.value()
        await fixture.rpc.enqueue(.response(Self.scanResponse(revision: "new")), for: "terminal.artifact.scan")
        await store.activate(identity: Self.identity(surfaceID: "new"))
        _ = try? await loading.value
        #expect(store.retiredOperationCount == 1)
        #expect(await fixture.cache.partialFileCount() == 0)
        let drain = Task { await store.waitForRetiredOperationsToDrain() }
        await metadata.releaseSecure()
        await drain.value

        #expect(store.retiredOperationCount == 0)
        #expect(await fixture.cache.containsFullContent(for: key) == false)
        #expect(store.viewerURL == nil)
        #expect(store.selection == nil)
    }

    @Test @MainActor
    func dismissedViewerRetiresSuspendedViewerCreationWithoutLatePublication() async throws {
        let metadata = SuspendingTerminalArtifactFileMetadata(extensionName: "image")
        let fixture = try StoreFixture(fileMetadata: metadata)
        defer { fixture.cleanup() }
        await fixture.rpc.enqueue(.response(Self.scanResponse(revision: "r1", bytes: Self.pngBytes.count)), for: "terminal.artifact.scan")
        let store = fixture.makeStore()
        await store.activate(identity: Self.identity())
        let artifact = try #require(store.artifacts.first)
        try await fixture.cache.storeFullData(Self.pngBytes, for: fixture.fullKey(revision: "r1"))
        let publication = await metadata.expectSecure()

        let opening = Task { try await store.openViewer(for: artifact) }
        await publication.value()
        await store.dismissViewer()
        _ = try? await opening.value

        #expect(store.retiredOperationCount == 1)
        #expect(store.viewerURL == nil)
        #expect(store.selection == nil)
        #expect(await fixture.cache.partialFileCount() == 0)
        #expect(await fixture.cache.viewerFileCount() == 0)
        let drain = Task { await store.waitForRetiredOperationsToDrain() }
        await metadata.releaseSecure()
        await drain.value
        #expect(store.retiredOperationCount == 0)
        #expect(await fixture.cache.viewerFileCount() == 0)
    }

    @Test @MainActor
    func testEnforcesByteAndPixelCapsBeforePublication() async throws {
        let fixture = try StoreFixture(imageDimensions: .init(width: 10_000, height: 5_000))
        defer { fixture.cleanup() }
        await fixture.rpc.enqueue(.response(Self.scanResponse(revision: "large", bytes: TerminalArtifactLimits.maxImageBytes + 1)), for: "terminal.artifact.scan")
        let store = fixture.makeStore()
        await store.activate(identity: Self.identity())
        let oversized = try #require(store.artifacts.first)
        await #expect(throws: TerminalArtifactStoreError.imageTooLarge) {
            _ = try await store.openViewer(for: oversized)
        }
        #expect(await fixture.rpc.callCount(method: "terminal.artifact.stat") == 0)
        #expect(await fixture.rpc.callCount(method: "terminal.artifact.fetch") == 0)

        await fixture.rpc.enqueue(.response(Self.scanResponse(revision: "pixels", bytes: Self.pngBytes.count)), for: "terminal.artifact.scan")
        await fixture.rpc.enqueue(.response(Self.statResponse(revision: "pixels", bytes: Self.pngBytes.count, width: 10_000, height: 5_000)), for: "terminal.artifact.stat")
        await store.activate(identity: Self.identity(surfaceID: "pixels"))
        let tooManyPixels = try #require(store.artifacts.first)
        await #expect(throws: TerminalArtifactStoreError.tooManyPixels) {
            _ = try await store.openViewer(for: tooManyPixels)
        }
        #expect(await fixture.rpc.callCount(method: "terminal.artifact.fetch") == 0)
        #expect(store.viewerURL == nil)
    }

    @Test @MainActor
    func testUnavailableRPCAndGenericRowsRemainIsolated() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        await fixture.rpc.enqueue(.response(RPCResponse(id: "scan", ok: false, error: RPCError(code: "method_not_found", message: "unsupported"))), for: "terminal.artifact.scan")
        let store = fixture.makeStore()
        await store.activate(identity: Self.identity())
        #expect(store.state == .unavailable)
        #expect(store.artifacts.isEmpty)

        let document = TerminalArtifact(artifactId: "doc", filename: "notes.pdf", mimeType: "application/pdf", bytes: 20, revision: "d1", isImage: false)
        await #expect(throws: TerminalArtifactStoreError.notAnImage) {
            _ = try await store.thumbnail(for: document, dimension: 512)
        }
        await #expect(throws: TerminalArtifactStoreError.notAnImage) {
            _ = try await store.openViewer(for: document)
        }
        #expect(await fixture.rpc.callCount(method: "terminal.artifact.thumbnail") == 0)
        #expect(await fixture.rpc.callCount(method: "terminal.artifact.stat") == 0)
        #expect(await fixture.rpc.callCount(method: "terminal.artifact.fetch") == 0)
    }

    private static let pngBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    private static func identity(surfaceID: String = "surface", hostGeneration: Int = 7) -> TerminalArtifactIdentity {
        TerminalArtifactIdentity(hostID: "host", accountScope: "account", hostGeneration: hostGeneration, workspaceID: "workspace", surfaceID: surfaceID)
    }

    private static func scanResponse(revision: String, filename: String = "photo.png", bytes: Int = pngBytes.count, includeDocument: Bool = false) -> RPCResponse {
        var artifacts: [JSONValue] = [.object([
            "artifact_id": .string("artifact"), "filename": .string(filename), "mime_type": .string("image/png"),
            "bytes": .int(Int64(bytes)), "revision": .string(revision), "is_image": .bool(true),
        ])]
        if includeDocument {
            artifacts.append(.object([
                "artifact_id": .string("document"), "filename": .string("notes.pdf"), "mime_type": .string("application/pdf"),
                "bytes": .int(12), "revision": .string("document-r1"), "is_image": .bool(false),
            ]))
        }
        return RPCResponse(id: "scan", result: .object(["generation": .int(3), "artifacts": .array(artifacts)]))
    }

    private static func statResponse(revision: String, bytes: Int, width: Int, height: Int) -> RPCResponse {
        RPCResponse(id: "stat", result: .object([
            "artifact_id": .string("artifact"), "filename": .string("photo.png"), "mime_type": .string("image/png"),
            "bytes": .int(Int64(bytes)), "revision": .string(revision), "width": .int(Int64(width)), "height": .int(Int64(height)),
        ]))
    }

    private static func fetchResponse<D: DataProtocol>(offset: Int, total: Int, revision: String, data: D, eof: Bool) -> RPCResponse {
        RPCResponse(id: "fetch", result: .object([
            "artifact_id": .string("artifact"), "offset": .int(Int64(offset)), "total_bytes": .int(Int64(total)),
            "revision": .string(revision), "data_base64": .string(Data(data).base64EncodedString()), "eof": .bool(eof),
        ]))
    }

    private static func malformedResponse(_ malformed: MalformedFetchCase, offset: Int) -> RPCResponse {
        let remaining = pngBytes.dropFirst(offset)
        var object: [String: JSONValue] = [
            "artifact_id": .string("artifact"), "offset": .int(Int64(offset)), "total_bytes": .int(Int64(pngBytes.count)),
            "revision": .string("r1"), "data_base64": .string(Data(remaining).base64EncodedString()), "eof": .bool(true),
        ]
        switch malformed {
        case .offset: object["offset"] = .int(Int64(offset + 1))
        case .total: object["total_bytes"] = .int(Int64(pngBytes.count + 1))
        case .revision: object["revision"] = .string("r2")
        case .earlyEOF: object["data_base64"] = .string(Data(remaining.dropLast()).base64EncodedString())
        case .missingEOF: object["eof"] = .bool(false)
        case .base64: object["data_base64"] = .string("YQ")
        case .emptyNonEOF:
            object["data_base64"] = .string("")
            object["eof"] = .bool(false)
        }
        return RPCResponse(id: "fetch", result: .object(object))
    }

    private static func thumbnailResponse(revision: String) -> RPCResponse {
        RPCResponse(id: "thumbnail", result: .object([
            "artifact_id": .string("artifact"), "revision": .string(revision), "dimension": .int(512),
            "width": .int(1), "height": .int(1), "mime_type": .string("image/png"), "data_base64": .string(pngBytes.base64EncodedString()),
        ]))
    }
}

private enum MalformedFetchCase: CaseIterable, Sendable {
    case offset, total, revision, earlyEOF, missingEOF, base64, emptyNonEOF
}

private struct StoreFixture {
    let root: URL
    let rpc = TerminalArtifactRPCStub()
    let cache: TerminalArtifactCache
    let imageInspector: FixedTerminalArtifactImageInspector

    init(
        imageDimensions: TerminalArtifactImageDimensions = .init(width: 1, height: 1),
        fileMetadata: (any TerminalArtifactFileMetadataApplying)? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-artifact-store-tests-\(UUID().uuidString)", isDirectory: true)
        cache = TerminalArtifactCache(rootURL: root, clock: FixedTerminalArtifactClock(), fileMetadata: fileMetadata)
        imageInspector = FixedTerminalArtifactImageInspector(dimensions: imageDimensions)
    }

    @MainActor func makeStore() -> TerminalArtifactStore {
        TerminalArtifactStore(rpc: rpc, cache: cache, imageInspector: imageInspector)
    }

    func fullKey(revision: String) -> TerminalArtifactCacheKey {
        TerminalArtifactCacheKey(hostID: "host", accountScope: "account", pathToken: "artifact", revision: revision)
    }

    func thumbnailKey(revision: String) -> TerminalArtifactThumbnailCacheKey {
        TerminalArtifactThumbnailCacheKey(hostID: "host", accountScope: "account", pathToken: "artifact", revision: revision, dimension: 512)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private actor TerminalArtifactRPCStub: RPCDispatch {
    enum Plan: Sendable { case response(RPCResponse), gate(String) }
    struct Call: Sendable { let method: String; let params: JSONValue }

    private var plans: [String: [Plan]] = [:]
    private var calls: [Call] = []
    private var continuations: [String: CheckedContinuation<RPCResponse, Error>] = [:]
    private var callExpectations: [String: [TerminalArtifactCallExpectation]] = [:]

    func enqueue(_ plan: Plan, for method: String) { plans[method, default: []].append(plan) }

    func expectCall(method: String) -> TerminalArtifactCallExpectation {
        let expectation = TerminalArtifactCallExpectation()
        callExpectations[method, default: []].append(expectation)
        return expectation
    }

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        let call = Call(method: method, params: params)
        calls.append(call)
        if var expectations = callExpectations[method], !expectations.isEmpty {
            let expectation = expectations.removeFirst()
            callExpectations[method] = expectations
            await expectation.fulfill(call)
        }
        guard var methodPlans = plans[method], !methodPlans.isEmpty else {
            return RPCResponse(id: "missing", ok: false, error: RPCError(code: "unexpected_call", message: method))
        }
        let plan = methodPlans.removeFirst()
        plans[method] = methodPlans
        switch plan {
        case .response(let response): return response
        case .gate(let id):
            return try await withCheckedThrowingContinuation { continuations[id] = $0 }
        }
    }

    func resolve(_ id: String, with response: RPCResponse) {
        continuations.removeValue(forKey: id)?.resume(returning: response)
    }

    func recordedCalls(method: String) -> [Call] { calls.filter { $0.method == method } }
    func callCount(method: String) -> Int { calls.count { $0.method == method } }
}

private actor TerminalArtifactCallExpectation {
    private var call: TerminalArtifactRPCStub.Call?
    private var waiters: [CheckedContinuation<TerminalArtifactRPCStub.Call, Never>] = []

    func fulfill(_ call: TerminalArtifactRPCStub.Call) {
        self.call = call
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters { waiter.resume(returning: call) }
    }

    func value() async -> TerminalArtifactRPCStub.Call {
        if let call { return call }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private actor TerminalArtifactVoidExpectation {
    private var fulfilled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fulfill() {
        fulfilled = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters { waiter.resume() }
    }

    func value() async {
        if fulfilled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor SuspendingTerminalArtifactFileMetadata: TerminalArtifactFileMetadataApplying {
    private let extensionName: String
    private var entryExpectations: [TerminalArtifactVoidExpectation] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    init(extensionName: String) {
        self.extensionName = extensionName
    }

    func expectSecure() -> TerminalArtifactVoidExpectation {
        let expectation = TerminalArtifactVoidExpectation()
        entryExpectations.append(expectation)
        return expectation
    }

    func secure(_ url: URL) async {
        guard url.pathExtension == extensionName else { return }
        if !entryExpectations.isEmpty {
            let expectation = entryExpectations.removeFirst()
            await expectation.fulfill()
        }
        await withCheckedContinuation { releases.append($0) }
    }

    func releaseSecure() {
        let currentReleases = releases
        releases.removeAll()
        for release in currentReleases { release.resume() }
    }
}

private struct FixedTerminalArtifactClock: TerminalArtifactClock {
    func now() async -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
}

private struct FixedTerminalArtifactImageInspector: TerminalArtifactImageInspecting {
    let dimensions: TerminalArtifactImageDimensions
    func dimensions(of url: URL) throws -> TerminalArtifactImageDimensions { dimensions }
}
