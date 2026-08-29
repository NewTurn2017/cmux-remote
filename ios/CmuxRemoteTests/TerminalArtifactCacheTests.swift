import Foundation
import Testing
@testable import CmuxRemote

@Suite("TerminalArtifactCacheTests", .serialized, .timeLimit(.minutes(1)))
struct TerminalArtifactCacheTests {
    @Test
    func fullContentUsesBoundedMemoryAndDiskLRU() async throws {
        let clock = AdvancingTerminalArtifactClock()
        let fixture = try CacheFixture(clock: clock, memoryLimit: 8, fullDiskLimit: 10, thumbnailDiskLimit: 10)
        defer { fixture.cleanup() }
        let first = fixture.key(path: "/Users/alice/private/first.png", revision: "r1")
        let second = fixture.key(path: "/Users/alice/private/second.png", revision: "r1")

        try await fixture.cache.storeFullData(Data(repeating: 1, count: 6), for: first)
        await clock.advance()
        try await fixture.cache.storeFullData(Data(repeating: 2, count: 6), for: second)

        #expect(await fixture.cache.memoryUsageBytes() <= 8)
        #expect(await fixture.cache.fullDiskUsageBytes() <= 10)
        #expect(await fixture.cache.fullEntryCount() == 1)
        #expect(await fixture.cache.containsFullContent(for: first) == false)
        #expect(await fixture.cache.containsFullContent(for: second))
        #expect(await fixture.cache.fullData(for: second) == Data(repeating: 2, count: 6))
    }

    @Test
    func thumbnailDiskLRUAndMemoryCacheAreBounded() async throws {
        let clock = AdvancingTerminalArtifactClock()
        let fixture = try CacheFixture(clock: clock, memoryLimit: 8, fullDiskLimit: 20, thumbnailDiskLimit: 10)
        defer { fixture.cleanup() }
        let first = fixture.thumbnailKey(path: "first", revision: "r1", dimension: 512)
        let second = fixture.thumbnailKey(path: "second", revision: "r1", dimension: 512)

        try await fixture.cache.storeThumbnail(Data(repeating: 3, count: 6), for: first)
        await clock.advance()
        try await fixture.cache.storeThumbnail(Data(repeating: 4, count: 6), for: second)

        #expect(await fixture.cache.thumbnailDiskUsageBytes() <= 10)
        #expect(await fixture.cache.thumbnailEntryCount() == 1)
        #expect(await fixture.cache.thumbnail(for: first) == nil)
        #expect(await fixture.cache.thumbnail(for: second) == Data(repeating: 4, count: 6))
    }

    @Test
    func filenamesAreHashedAndFilesHavePrivateMetadata() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let rawPath = "/Users/alice/Secret Projects/customer-image.png"
        let key = fixture.key(path: rawPath, revision: "revision-visible-only-in-key")
        let thumbnailKey = fixture.thumbnailKey(path: rawPath, revision: "revision-visible-only-in-key", dimension: 512)

        try await fixture.cache.storeFullData(Data([1, 2, 3]), for: key)
        try await fixture.cache.storeThumbnail(Data([4, 5, 6]), for: thumbnailKey)
        let files = await fixture.cache.diskFileURLs()

        #expect(files.count == 2)
        let securedPaths = await fixture.metadata.securedPaths()
        for file in files {
            #expect(!file.lastPathComponent.contains("alice"))
            #expect(!file.lastPathComponent.contains("customer"))
            #expect(!file.lastPathComponent.contains("revision"))
            #expect(file.lastPathComponent.range(of: "^[0-9a-f]{64}\\.(artifact|thumb)$", options: .regularExpression) != nil)
            let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true)
            #expect(securedPaths.contains { URL(fileURLWithPath: $0).pathExtension == file.pathExtension })
        }
    }

    @Test
    func revisionInvalidationRemovesMemoryAndDiskEntries() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let old = fixture.key(path: "artifact", revision: "old")
        let current = fixture.key(path: "artifact", revision: "current")
        let oldThumbnail = fixture.thumbnailKey(path: "artifact", revision: "old", dimension: 512)
        let currentThumbnail = fixture.thumbnailKey(path: "artifact", revision: "current", dimension: 512)
        try await fixture.cache.storeFullData(Data([1]), for: old)
        try await fixture.cache.storeFullData(Data([2]), for: current)
        try await fixture.cache.storeThumbnail(Data([3]), for: oldThumbnail)
        try await fixture.cache.storeThumbnail(Data([4]), for: currentThumbnail)

        await fixture.cache.invalidateRevisions(hostID: "host", accountScope: "account", pathToken: "artifact", keeping: "current")

        #expect(await fixture.cache.containsFullContent(for: old) == false)
        #expect(await fixture.cache.containsFullContent(for: current))
        #expect(await fixture.cache.thumbnail(for: oldThumbnail) == nil)
        #expect(await fixture.cache.thumbnail(for: currentThumbnail) == Data([4]))
    }

    @Test
    func recreatedCacheInvalidatesOldRevisionFromPersistentHashedIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-artifact-recreation-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = TerminalArtifactCacheKey(hostID: "host", accountScope: "account", pathToken: "/private/customer.png", revision: "old")
        let metadata = RecordingTerminalArtifactFileMetadata()
        let firstCache = TerminalArtifactCache(rootURL: root, clock: ConstantTerminalArtifactClock(), fileMetadata: metadata)
        try await firstCache.storeFullData(Data([1, 2, 3]), for: old)
        #expect(await firstCache.containsFullContent(for: old))

        let recreated = TerminalArtifactCache(rootURL: root, clock: ConstantTerminalArtifactClock(), fileMetadata: metadata)
        await recreated.invalidateRevisions(hostID: "host", accountScope: "account", pathToken: "/private/customer.png", keeping: "new")

        #expect(await recreated.containsFullContent(for: old) == false)
        #expect(await recreated.fullEntryCount() == 0)
        let indexData = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let indexText = String(decoding: indexData, as: UTF8.self)
        #expect(!indexText.contains("customer"))
        #expect(!indexText.contains("/private"))
    }

    @Test
    func equalClockDiskLRUUsesPersistentAccessOrdinal() async throws {
        let fixture = try CacheFixture(clock: ConstantTerminalArtifactClock(), memoryLimit: 0, fullDiskLimit: 12)
        defer { fixture.cleanup() }
        let first = fixture.key(path: "first", revision: "r1")
        let second = fixture.key(path: "second", revision: "r1")
        let third = fixture.key(path: "third", revision: "r1")
        try await fixture.cache.storeFullData(Data(repeating: 1, count: 6), for: first)
        try await fixture.cache.storeFullData(Data(repeating: 2, count: 6), for: second)
        #expect(await fixture.cache.fullData(for: first) == Data(repeating: 1, count: 6))
        try await fixture.cache.storeFullData(Data(repeating: 3, count: 6), for: third)

        #expect(await fixture.cache.containsFullContent(for: first))
        #expect(await fixture.cache.containsFullContent(for: second) == false)
        #expect(await fixture.cache.containsFullContent(for: third))
    }

    @Test
    func fullMetadataFailureRollsBackDestinationPartialAndLookup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-artifact-full-secure-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = ExtensionFailingTerminalArtifactFileMetadata(extensionName: "artifact")
        let cache = TerminalArtifactCache(rootURL: root, clock: ConstantTerminalArtifactClock(), fileMetadata: metadata)
        let key = TerminalArtifactCacheKey(hostID: "host", accountScope: "account", pathToken: "artifact", revision: "r1")

        await #expect(throws: (any Error).self) {
            try await cache.storeFullData(Data([1, 2, 3]), for: key)
        }

        #expect(await cache.fullEntryCount() == 0)
        #expect(await cache.partialFileCount() == 0)
        #expect(await cache.containsFullContent(for: key) == false)
        #expect(await cache.fullData(for: key) == nil)
    }

    @Test
    func thumbnailMetadataFailureRollsBackDestinationPartialAndLookup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-artifact-thumb-secure-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = ExtensionFailingTerminalArtifactFileMetadata(extensionName: "thumb")
        let cache = TerminalArtifactCache(rootURL: root, clock: ConstantTerminalArtifactClock(), fileMetadata: metadata)
        let key = TerminalArtifactThumbnailCacheKey(hostID: "host", accountScope: "account", pathToken: "artifact", revision: "r1", dimension: 512)

        await #expect(throws: (any Error).self) {
            try await cache.storeThumbnail(Data([4, 5, 6]), for: key)
        }

        #expect(await cache.thumbnailEntryCount() == 0)
        #expect(await cache.partialFileCount() == 0)
        #expect(await cache.thumbnail(for: key) == nil)
    }

    @Test
    func retiredThumbnailOperationCannotPublishAfterSuspendedSecurityStep() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-artifact-retired-thumb-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = GatedTerminalArtifactFileMetadata(extensionName: "thumb")
        let cache = TerminalArtifactCache(rootURL: root, clock: ConstantTerminalArtifactClock(), fileMetadata: metadata)
        let key = TerminalArtifactThumbnailCacheKey(hostID: "host", accountScope: "account", pathToken: "artifact", revision: "r1", dimension: 512)
        let operationID = UUID()
        try await cache.beginOperation(operationID)
        var entries = await metadata.entries().makeAsyncIterator()
        let storing = Task { try await cache.storeThumbnail(Data([1, 2, 3]), for: key, operationID: operationID) }

        _ = await entries.next()
        await cache.retireOperation(operationID)
        #expect(await cache.partialFileCount() == 0)
        await metadata.release()
        await #expect(throws: (any Error).self) { try await storing.value }
        await cache.finishOperation(operationID)

        #expect(await cache.thumbnail(for: key) == nil)
        #expect(await cache.thumbnailEntryCount() == 0)
    }

    @Test
    func retiredFullOperationCannotCommitAfterSuspendedSecurityStep() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-artifact-retired-full-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = GatedTerminalArtifactFileMetadata(extensionName: "artifact")
        let cache = TerminalArtifactCache(rootURL: root, clock: ConstantTerminalArtifactClock(), fileMetadata: metadata)
        let key = TerminalArtifactCacheKey(hostID: "host", accountScope: "account", pathToken: "artifact", revision: "r1")
        let operationID = UUID()
        try await cache.beginOperation(operationID)
        let write = try await cache.beginFullWrite(for: key, operationID: operationID)
        try await cache.append(Data([1, 2, 3]), to: write)
        var entries = await metadata.entries().makeAsyncIterator()
        let committing = Task { try await cache.commitFullWrite(write, expectedBytes: 3) }

        _ = await entries.next()
        await cache.retireOperation(operationID)
        #expect(await cache.partialFileCount() == 0)
        await metadata.release()
        await #expect(throws: (any Error).self) { try await committing.value }
        await cache.finishOperation(operationID)

        #expect(await cache.containsFullContent(for: key) == false)
        #expect(await cache.fullEntryCount() == 0)
    }

    @Test
    func retiredViewerOperationCannotPublishAfterSuspendedSecurityStep() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-artifact-retired-viewer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = GatedTerminalArtifactFileMetadata(extensionName: "image")
        let cache = TerminalArtifactCache(rootURL: root, clock: ConstantTerminalArtifactClock(), fileMetadata: metadata)
        let key = TerminalArtifactCacheKey(hostID: "host", accountScope: "account", pathToken: "artifact", revision: "r1")
        try await cache.storeFullData(Data([1, 2, 3]), for: key)
        let operationID = UUID()
        try await cache.beginOperation(operationID)
        var entries = await metadata.entries().makeAsyncIterator()
        let makingViewer = Task { try await cache.makeViewerURL(for: key, operationID: operationID) }

        _ = await entries.next()
        await cache.retireOperation(operationID)
        #expect(await cache.partialFileCount() == 0)
        #expect(await cache.viewerFileCount() == 0)
        await metadata.release()
        await #expect(throws: (any Error).self) { _ = try await makingViewer.value }
        await cache.finishOperation(operationID)

        #expect(await cache.viewerFileCount() == 0)
    }

    @Test
    func partialCommitIsAtomicAndAbortLeavesNoFile() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let key = fixture.key(path: "artifact", revision: "r1")

        let aborted = try await fixture.cache.beginFullWrite(for: key)
        try await fixture.cache.append(Data([1, 2]), to: aborted)
        #expect(await fixture.cache.partialFileCount() == 1)
        await fixture.cache.abortFullWrite(aborted)
        #expect(await fixture.cache.partialFileCount() == 0)
        #expect(await fixture.cache.fullEntryCount() == 0)

        let committed = try await fixture.cache.beginFullWrite(for: key)
        try await fixture.cache.append(Data([3, 4, 5]), to: committed)
        try await fixture.cache.commitFullWrite(committed, expectedBytes: 3)
        #expect(await fixture.cache.partialFileCount() == 0)
        #expect(await fixture.cache.fullData(for: key) == Data([3, 4, 5]))
    }

    @Test
    func viewerFilesAndHostResetArePurged() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let key = fixture.key(path: "artifact", revision: "r1")
        try await fixture.cache.storeFullData(Data([7, 8, 9]), for: key)
        let viewer = try #require(await fixture.cache.makeViewerURL(for: key))
        #expect(FileManager.default.fileExists(atPath: viewer.path))

        await fixture.cache.removeViewerURL(viewer)
        #expect(!FileManager.default.fileExists(atPath: viewer.path))
        await fixture.cache.purgeAll()
        #expect(await fixture.cache.fullEntryCount() == 0)
        #expect(await fixture.cache.thumbnailEntryCount() == 0)
        #expect(await fixture.cache.memoryUsageBytes() == 0)
        #expect(await fixture.cache.partialFileCount() == 0)
    }
}

private actor GatedTerminalArtifactFileMetadata: TerminalArtifactFileMetadataApplying {
    private let extensionName: String
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var releases: [CheckedContinuation<Void, Never>] = []

    init(extensionName: String) {
        self.extensionName = extensionName
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func entries() -> AsyncStream<Void> { stream }

    func secure(_ url: URL) async {
        guard url.pathExtension == extensionName else { return }
        continuation.yield(())
        await withCheckedContinuation { releases.append($0) }
    }

    func release() {
        let current = releases
        releases.removeAll()
        for continuation in current { continuation.resume() }
    }
}

private struct CacheFixture {
    let root: URL
    let clock: any TerminalArtifactClock
    let metadata: RecordingTerminalArtifactFileMetadata
    let cache: TerminalArtifactCache

    init(
        clock: any TerminalArtifactClock = AdvancingTerminalArtifactClock(),
        memoryLimit: Int = 16 * 1024 * 1024,
        fullDiskLimit: Int = 128 * 1024 * 1024,
        thumbnailDiskLimit: Int = 32 * 1024 * 1024
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-artifact-cache-tests-\(UUID().uuidString)", isDirectory: true)
        self.clock = clock
        let metadata = RecordingTerminalArtifactFileMetadata()
        self.metadata = metadata
        cache = TerminalArtifactCache(
            rootURL: root,
            clock: clock,
            fileMetadata: metadata,
            memoryByteLimit: memoryLimit,
            fullDiskByteLimit: fullDiskLimit,
            thumbnailDiskByteLimit: thumbnailDiskLimit
        )
    }

    func key(path: String, revision: String) -> TerminalArtifactCacheKey {
        TerminalArtifactCacheKey(hostID: "host", accountScope: "account", pathToken: path, revision: revision)
    }

    func thumbnailKey(path: String, revision: String, dimension: Int) -> TerminalArtifactThumbnailCacheKey {
        TerminalArtifactThumbnailCacheKey(hostID: "host", accountScope: "account", pathToken: path, revision: revision, dimension: dimension)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private actor AdvancingTerminalArtifactClock: TerminalArtifactClock {
    private var value = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { value }
    func advance() { value = value.addingTimeInterval(1) }
}

private struct ConstantTerminalArtifactClock: TerminalArtifactClock {
    func now() async -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
}

private actor RecordingTerminalArtifactFileMetadata: TerminalArtifactFileMetadataApplying {
    private let production = FoundationTerminalArtifactFileMetadata()
    private var paths: Set<String> = []

    func secure(_ url: URL) async throws {
        try await production.secure(url)
        paths.insert(url.path)
    }

    func securedPaths() -> Set<String> { paths }
}

private actor ExtensionFailingTerminalArtifactFileMetadata: TerminalArtifactFileMetadataApplying {
    private let extensionName: String

    init(extensionName: String) {
        self.extensionName = extensionName
    }

    func secure(_ url: URL) throws {
        if url.pathExtension == extensionName {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
