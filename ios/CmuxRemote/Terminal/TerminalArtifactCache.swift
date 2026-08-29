import CryptoKit
import Foundation

actor TerminalArtifactCache {
    static let defaultMemoryByteLimit = 16 * 1024 * 1024
    static let defaultFullDiskByteLimit = 128 * 1024 * 1024
    static let defaultThumbnailDiskByteLimit = 32 * 1024 * 1024

    private struct MemoryEntry {
        let data: Data
        var access: UInt64
    }

    private struct PartialEntry {
        let key: TerminalArtifactCacheKey
        let url: URL
        let operationID: UUID?
    }

    private struct OperationResources {
        var partialIDs: Set<UUID> = []
        var stagingURLs: Set<URL> = []
        var viewerURLs: Set<URL> = []
        var fullDigests: Set<String> = []
        var thumbnailDigests: Set<String> = []
    }

    private let rootURL: URL
    private let fullURL: URL
    private let thumbnailURL: URL
    private let partialURL: URL
    private let viewerURL: URL
    private let indexURL: URL
    private let clock: any TerminalArtifactClock
    private let fileMetadata: any TerminalArtifactFileMetadataApplying
    private let memoryByteLimit: Int
    private let fullDiskByteLimit: Int
    private let thumbnailDiskByteLimit: Int
    private let fileManager: FileManager
    private let thumbnailMemory = NSCache<NSString, NSData>()

    private var memory: [String: MemoryEntry] = [:]
    private var memoryBytes = 0
    private var accessSequence: UInt64
    private var partials: [UUID: PartialEntry] = [:]
    private var operationActive: [UUID: Bool] = [:]
    private var operationResources: [UUID: OperationResources] = [:]
    private var index: TerminalArtifactCacheIndex

    init(
        rootURL: URL,
        clock: any TerminalArtifactClock = SystemTerminalArtifactClock(),
        fileManager: FileManager = FileManager(),
        fileMetadata: (any TerminalArtifactFileMetadataApplying)? = nil,
        memoryByteLimit: Int = TerminalArtifactCache.defaultMemoryByteLimit,
        fullDiskByteLimit: Int = TerminalArtifactCache.defaultFullDiskByteLimit,
        thumbnailDiskByteLimit: Int = TerminalArtifactCache.defaultThumbnailDiskByteLimit
    ) {
        self.rootURL = rootURL
        self.fullURL = rootURL.appendingPathComponent("full", isDirectory: true)
        self.thumbnailURL = rootURL.appendingPathComponent("thumbnails", isDirectory: true)
        self.partialURL = rootURL.appendingPathComponent("partials", isDirectory: true)
        self.viewerURL = rootURL.appendingPathComponent("viewers", isDirectory: true)
        self.indexURL = rootURL.appendingPathComponent("index.json")
        self.clock = clock
        self.fileMetadata = fileMetadata ?? FoundationTerminalArtifactFileMetadata()
        self.memoryByteLimit = max(0, memoryByteLimit)
        self.fullDiskByteLimit = max(0, fullDiskByteLimit)
        self.thumbnailDiskByteLimit = max(0, thumbnailDiskByteLimit)
        self.fileManager = fileManager
        self.thumbnailMemory.totalCostLimit = min(TerminalArtifactCache.defaultMemoryByteLimit, max(0, memoryByteLimit))

        Self.prepareDirectory(rootURL, using: fileManager)
        Self.prepareDirectory(fullURL, using: fileManager)
        Self.prepareDirectory(thumbnailURL, using: fileManager)
        try? fileManager.removeItem(at: partialURL)
        try? fileManager.removeItem(at: viewerURL)
        Self.prepareDirectory(partialURL, using: fileManager)
        Self.prepareDirectory(viewerURL, using: fileManager)

        var loadedIndex = Self.loadIndex(from: indexURL) ?? .empty
        Self.reconcile(&loadedIndex, fullURL: fullURL, thumbnailURL: thumbnailURL, fileManager: fileManager)
        self.index = loadedIndex
        self.accessSequence = loadedIndex.accessOrdinal
        try? Self.persist(loadedIndex, to: indexURL, fileManager: fileManager)
    }

    func fullData(for key: TerminalArtifactCacheKey) async -> Data? {
        let digest = Self.digest(for: key)
        guard index.entries[digest]?.kind == .full else { return nil }
        if var entry = memory[digest] {
            accessSequence &+= 1
            entry.access = accessSequence
            memory[digest] = entry
            await touch(digest: digest, url: fullFileURL(digest: digest))
            return entry.data
        }
        let url = fullFileURL(digest: digest)
        guard let data = try? Data(contentsOf: url) else {
            removeFull(digest: digest)
            try? persistIndex()
            return nil
        }
        insertMemory(data, digest: digest)
        await touch(digest: digest, url: url)
        return data
    }

    func containsFullContent(for key: TerminalArtifactCacheKey) -> Bool {
        let digest = Self.digest(for: key)
        guard index.entries[digest]?.kind == .full else { return false }
        return fileManager.fileExists(atPath: fullFileURL(digest: digest).path)
    }

    func beginOperation(_ operationID: UUID) throws {
        if operationActive[operationID] == false { throw CancellationError() }
        operationActive[operationID] = true
        if operationResources[operationID] == nil { operationResources[operationID] = OperationResources() }
    }

    func retireOperation(_ operationID: UUID) {
        operationActive[operationID] = false
        guard let resources = operationResources[operationID] else { return }
        for partialID in resources.partialIDs {
            if let partial = partials.removeValue(forKey: partialID) { try? fileManager.removeItem(at: partial.url) }
        }
        for url in resources.stagingURLs { try? fileManager.removeItem(at: url) }
        for url in resources.viewerURLs { try? fileManager.removeItem(at: url) }
        for digest in resources.fullDigests { removeFull(digest: digest) }
        for digest in resources.thumbnailDigests { removeThumbnail(digest: digest) }
        try? persistIndex()
    }

    func finishOperation(_ operationID: UUID) {
        if let resources = operationResources.removeValue(forKey: operationID) {
            for partialID in resources.partialIDs {
                if let partial = partials.removeValue(forKey: partialID) { try? fileManager.removeItem(at: partial.url) }
            }
            for url in resources.stagingURLs { try? fileManager.removeItem(at: url) }
        }
        operationActive[operationID] = nil
    }

    func storeFullData(_ data: Data, for key: TerminalArtifactCacheKey) async throws {
        let write = try beginFullWrite(for: key)
        do {
            try append(data, to: write)
            try await commitFullWrite(write, expectedBytes: data.count)
        } catch {
            abortFullWrite(write)
            throw error
        }
    }

    func beginFullWrite(for key: TerminalArtifactCacheKey, operationID: UUID? = nil) throws -> TerminalArtifactPartialWrite {
        try ensureActive(operationID)
        let write = TerminalArtifactPartialWrite()
        let url = partialURL.appendingPathComponent("\(write.id.uuidString.lowercased()).artifact")
        guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        partials[write.id] = PartialEntry(key: key, url: url, operationID: operationID)
        if let operationID { operationResources[operationID, default: OperationResources()].partialIDs.insert(write.id) }
        return write
    }

    func append(_ data: Data, to write: TerminalArtifactPartialWrite) throws {
        guard let partial = partials[write.id] else { throw CocoaError(.fileNoSuchFile) }
        try ensureActive(partial.operationID)
        let handle = try FileHandle(forWritingTo: partial.url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func partialFileURL(for write: TerminalArtifactPartialWrite) -> URL? {
        partials[write.id]?.url
    }

    func commitFullWrite(_ write: TerminalArtifactPartialWrite, expectedBytes: Int) async throws {
        guard let initialPartial = partials[write.id] else { throw CocoaError(.fileNoSuchFile) }
        try ensureActive(initialPartial.operationID)
        let partial = initialPartial
        let attributes = try fileManager.attributesOfItem(atPath: partial.url.path)
        guard (attributes[.size] as? NSNumber)?.intValue == expectedBytes else {
            abortFullWrite(write)
            throw CocoaError(.fileWriteUnknown)
        }
        let digest = Self.digest(for: partial.key)
        let destination = fullFileURL(digest: digest)
        do {
            try await fileMetadata.secure(partial.url)
            try Task.checkCancellation()
            guard let currentPartial = partials[write.id], currentPartial.url == partial.url else {
                throw CancellationError()
            }
            try ensureActive(partial.operationID)
            removeFull(digest: digest)
            try fileManager.moveItem(at: partial.url, to: destination)
            partials[write.id] = nil
            if let operationID = partial.operationID {
                operationResources[operationID, default: OperationResources()].partialIDs.remove(write.id)
                operationResources[operationID, default: OperationResources()].fullDigests.insert(digest)
            }
            registerFull(partial.key, digest: digest, bytes: expectedBytes)
            if let data = try? Data(contentsOf: destination) { insertMemory(data, digest: digest) }
            try persistIndex()
            try await purgeDisk(kind: .full, byteLimit: fullDiskByteLimit)
        } catch {
            if shouldRollbackPublication(for: partial.operationID) {
                try? fileManager.removeItem(at: destination)
                removeFull(digest: digest)
                try? persistIndex()
            }
            throw error
        }
    }

    func abortFullWrite(_ write: TerminalArtifactPartialWrite) {
        guard let partial = partials.removeValue(forKey: write.id) else { return }
        if let operationID = partial.operationID {
            operationResources[operationID, default: OperationResources()].partialIDs.remove(write.id)
        }
        try? fileManager.removeItem(at: partial.url)
    }

    func thumbnail(for key: TerminalArtifactThumbnailCacheKey) async -> Data? {
        let digest = Self.digest(for: key)
        guard index.entries[digest]?.kind == .thumbnail else { return nil }
        if let cached = thumbnailMemory.object(forKey: digest as NSString) {
            await touch(digest: digest, url: thumbnailFileURL(digest: digest))
            return cached as Data
        }
        let url = thumbnailFileURL(digest: digest)
        guard let data = try? Data(contentsOf: url) else {
            removeThumbnail(digest: digest)
            try? persistIndex()
            return nil
        }
        thumbnailMemory.setObject(data as NSData, forKey: digest as NSString, cost: data.count)
        await touch(digest: digest, url: url)
        return data
    }

    func storeThumbnail(_ data: Data, for key: TerminalArtifactThumbnailCacheKey, operationID: UUID? = nil) async throws {
        try ensureActive(operationID)
        let digest = Self.digest(for: key)
        let destination = thumbnailFileURL(digest: digest)
        let staging = partialURL.appendingPathComponent("\(UUID().uuidString.lowercased()).thumb")
        if let operationID { operationResources[operationID, default: OperationResources()].stagingURLs.insert(staging) }
        do {
            try data.write(to: staging, options: .atomic)
            try await fileMetadata.secure(staging)
            try Task.checkCancellation()
            try ensureActive(operationID)
            removeThumbnail(digest: digest)
            try fileManager.moveItem(at: staging, to: destination)
            if let operationID {
                operationResources[operationID, default: OperationResources()].stagingURLs.remove(staging)
                operationResources[operationID, default: OperationResources()].thumbnailDigests.insert(digest)
            }
            registerThumbnail(key, digest: digest, bytes: data.count)
            thumbnailMemory.setObject(data as NSData, forKey: digest as NSString, cost: data.count)
            try persistIndex()
            try await purgeDisk(kind: .thumbnail, byteLimit: thumbnailDiskByteLimit)
        } catch {
            try? fileManager.removeItem(at: staging)
            if shouldRollbackPublication(for: operationID) {
                try? fileManager.removeItem(at: destination)
                removeThumbnail(digest: digest)
                try? persistIndex()
            }
            throw error
        }
    }

    func invalidateRevisions(hostID: String, accountScope: String, pathToken: String, keeping revision: String) {
        invalidateRevisionsUnchecked(hostID: hostID, accountScope: accountScope, pathToken: pathToken, keeping: revision)
    }

    func invalidateRevisions(
        hostID: String,
        accountScope: String,
        pathToken: String,
        keeping revision: String,
        operationID: UUID
    ) throws {
        try ensureActive(operationID)
        invalidateRevisionsUnchecked(hostID: hostID, accountScope: accountScope, pathToken: pathToken, keeping: revision)
    }

    private func invalidateRevisionsUnchecked(hostID: String, accountScope: String, pathToken: String, keeping revision: String) {
        let hostDigest = Self.componentDigest(hostID)
        let accountDigest = Self.componentDigest(accountScope)
        let pathDigest = Self.componentDigest(pathToken)
        let keptRevisionDigest = Self.componentDigest(revision)
        let stale = index.entries.values.filter {
            $0.hostDigest == hostDigest
                && $0.accountDigest == accountDigest
                && $0.pathDigest == pathDigest
                && $0.revisionDigest != keptRevisionDigest
        }
        for entry in stale {
            if entry.kind == .full { removeFull(digest: entry.digest) }
            else { removeThumbnail(digest: entry.digest) }
        }
        try? persistIndex()
    }

    func removeFullContent(for key: TerminalArtifactCacheKey) {
        removeFull(digest: Self.digest(for: key))
        try? persistIndex()
    }

    func removeThumbnail(for key: TerminalArtifactThumbnailCacheKey) {
        removeThumbnail(digest: Self.digest(for: key))
        try? persistIndex()
    }

    func makeViewerURL(for key: TerminalArtifactCacheKey, operationID: UUID? = nil) async throws -> URL? {
        try ensureActive(operationID)
        let digest = Self.digest(for: key)
        guard index.entries[digest]?.kind == .full else { return nil }
        let source = fullFileURL(digest: digest)
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        let staging = partialURL.appendingPathComponent("\(UUID().uuidString.lowercased()).image")
        let destination = viewerURL.appendingPathComponent("\(digest)-\(UUID().uuidString.lowercased()).image")
        if let operationID {
            operationResources[operationID, default: OperationResources()].stagingURLs.insert(staging)
            operationResources[operationID, default: OperationResources()].viewerURLs.insert(destination)
        }
        do {
            try fileManager.copyItem(at: source, to: staging)
            try await fileMetadata.secure(staging)
            try Task.checkCancellation()
            try ensureActive(operationID)
            try fileManager.moveItem(at: staging, to: destination)
            if let operationID { operationResources[operationID, default: OperationResources()].stagingURLs.remove(staging) }
            await touch(digest: digest, url: source)
            return destination
        } catch {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func removeViewerURL(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == viewerURL.standardizedFileURL else { return }
        try? fileManager.removeItem(at: url)
    }

    func purgeAll() {
        memory.removeAll()
        memoryBytes = 0
        thumbnailMemory.removeAllObjects()
        partials.removeAll()
        index = .empty
        accessSequence = 0
        try? fileManager.removeItem(at: rootURL)
        Self.prepareDirectory(rootURL, using: fileManager)
        Self.prepareDirectory(fullURL, using: fileManager)
        Self.prepareDirectory(thumbnailURL, using: fileManager)
        Self.prepareDirectory(partialURL, using: fileManager)
        Self.prepareDirectory(viewerURL, using: fileManager)
        try? persistIndex()
    }

    func memoryUsageBytes() -> Int { memoryBytes }
    func partialFileCount() -> Int { Self.allFiles(in: partialURL, using: fileManager).count }
    func viewerFileCount() -> Int { Self.allFiles(in: viewerURL, using: fileManager).count }
    func fullEntryCount() -> Int { Self.files(in: fullURL, extensionName: "artifact", using: fileManager).count }
    func thumbnailEntryCount() -> Int { Self.files(in: thumbnailURL, extensionName: "thumb", using: fileManager).count }
    func fullDiskUsageBytes() -> Int { Self.diskUsage(in: fullURL, extensionName: "artifact", using: fileManager) }
    func thumbnailDiskUsageBytes() -> Int { Self.diskUsage(in: thumbnailURL, extensionName: "thumb", using: fileManager) }
    func diskFileURLs() -> [URL] {
        Self.files(in: fullURL, extensionName: "artifact", using: fileManager)
            + Self.files(in: thumbnailURL, extensionName: "thumb", using: fileManager)
    }

    private func ensureActive(_ operationID: UUID?) throws {
        guard let operationID else { return }
        guard operationActive[operationID] == true else { throw CancellationError() }
    }

    private func shouldRollbackPublication(for operationID: UUID?) -> Bool {
        guard let operationID else { return true }
        return operationActive[operationID] != false
    }

    private func registerFull(_ key: TerminalArtifactCacheKey, digest: String, bytes: Int) {
        accessSequence &+= 1
        index.accessOrdinal = accessSequence
        index.entries[digest] = TerminalArtifactCacheIndexEntry(
            digest: digest,
            kind: .full,
            hostDigest: Self.componentDigest(key.hostID),
            accountDigest: Self.componentDigest(key.accountScope),
            pathDigest: Self.componentDigest(key.pathToken),
            revisionDigest: Self.componentDigest(key.revision),
            dimension: nil,
            bytes: bytes,
            accessOrdinal: accessSequence
        )
    }

    private func registerThumbnail(_ key: TerminalArtifactThumbnailCacheKey, digest: String, bytes: Int) {
        accessSequence &+= 1
        index.accessOrdinal = accessSequence
        index.entries[digest] = TerminalArtifactCacheIndexEntry(
            digest: digest,
            kind: .thumbnail,
            hostDigest: Self.componentDigest(key.hostID),
            accountDigest: Self.componentDigest(key.accountScope),
            pathDigest: Self.componentDigest(key.pathToken),
            revisionDigest: Self.componentDigest(key.revision),
            dimension: key.dimension,
            bytes: bytes,
            accessOrdinal: accessSequence
        )
    }

    private func insertMemory(_ data: Data, digest: String) {
        guard data.count <= memoryByteLimit else { return }
        if let existing = memory[digest] { memoryBytes -= existing.data.count }
        accessSequence &+= 1
        memory[digest] = MemoryEntry(data: data, access: accessSequence)
        memoryBytes += data.count
        while memoryBytes > memoryByteLimit, let oldest = memory.min(by: {
            $0.value.access == $1.value.access ? $0.key < $1.key : $0.value.access < $1.value.access
        }) {
            memoryBytes -= oldest.value.data.count
            memory[oldest.key] = nil
        }
    }

    private func removeFull(digest: String) {
        if let entry = memory.removeValue(forKey: digest) { memoryBytes -= entry.data.count }
        index.entries[digest] = nil
        try? fileManager.removeItem(at: fullFileURL(digest: digest))
    }

    private func removeThumbnail(digest: String) {
        thumbnailMemory.removeObject(forKey: digest as NSString)
        index.entries[digest] = nil
        try? fileManager.removeItem(at: thumbnailFileURL(digest: digest))
    }

    private func purgeDisk(kind: TerminalArtifactCacheEntryKind, byteLimit: Int) async throws {
        let entries = index.entries.values.filter { $0.kind == kind }
        var total = entries.reduce(0) { $0 + $1.bytes }
        let ordered = entries.sorted {
            $0.accessOrdinal == $1.accessOrdinal ? $0.digest < $1.digest : $0.accessOrdinal < $1.accessOrdinal
        }
        for entry in ordered where total > byteLimit {
            total -= entry.bytes
            if kind == .full { removeFull(digest: entry.digest) }
            else { removeThumbnail(digest: entry.digest) }
        }
        try persistIndex()
    }

    private func touch(digest: String, url: URL) async {
        guard fileManager.fileExists(atPath: url.path), var entry = index.entries[digest] else { return }
        accessSequence &+= 1
        index.accessOrdinal = accessSequence
        entry.accessOrdinal = accessSequence
        index.entries[digest] = entry
        try? persistIndex()
        let date = await clock.now()
        try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func persistIndex() throws {
        try Self.persist(index, to: indexURL, fileManager: fileManager)
    }

    private func fullFileURL(digest: String) -> URL { fullURL.appendingPathComponent("\(digest).artifact") }
    private func thumbnailFileURL(digest: String) -> URL { thumbnailURL.appendingPathComponent("\(digest).thumb") }

    private static func digest(for key: TerminalArtifactCacheKey) -> String {
        hash([key.hostID, key.accountScope, key.pathToken, key.revision])
    }

    private static func digest(for key: TerminalArtifactThumbnailCacheKey) -> String {
        hash([key.hostID, key.accountScope, key.pathToken, key.revision, String(key.dimension)])
    }

    private static func componentDigest(_ value: String) -> String {
        hash([value])
    }

    private static func hash(_ components: [String]) -> String {
        let framed = components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadIndex(from url: URL) -> TerminalArtifactCacheIndex? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TerminalArtifactCacheIndex.self, from: data)
    }

    private static func persist(_ index: TerminalArtifactCacheIndex, to url: URL, fileManager: FileManager) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var secured = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try secured.setResourceValues(values)
    }

    private static func reconcile(
        _ index: inout TerminalArtifactCacheIndex,
        fullURL: URL,
        thumbnailURL: URL,
        fileManager: FileManager
    ) {
        index.entries = index.entries.filter { digest, entry in
            let directory = entry.kind == .full ? fullURL : thumbnailURL
            let extensionName = entry.kind == .full ? "artifact" : "thumb"
            return fileManager.fileExists(atPath: directory.appendingPathComponent("\(digest).\(extensionName)").path)
        }
        let indexed = Set(index.entries.keys)
        for file in files(in: fullURL, extensionName: "artifact", using: fileManager)
            + files(in: thumbnailURL, extensionName: "thumb", using: fileManager) {
            if !indexed.contains(file.deletingPathExtension().lastPathComponent) {
                try? fileManager.removeItem(at: file)
            }
        }
        index.accessOrdinal = max(index.accessOrdinal, index.entries.values.map(\.accessOrdinal).max() ?? 0)
    }

    private static func prepareDirectory(_ url: URL, using fileManager: FileManager) {
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var secured = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? secured.setResourceValues(values)
    }

    private static func allFiles(in directory: URL, using fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private static func files(in directory: URL, extensionName: String, using fileManager: FileManager) -> [URL] {
        allFiles(in: directory, using: fileManager).filter { $0.pathExtension == extensionName }
    }

    private static func diskUsage(in directory: URL, extensionName: String, using fileManager: FileManager) -> Int {
        files(in: directory, extensionName: extensionName, using: fileManager).reduce(0) { total, url in
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return total + ((attributes?[.size] as? NSNumber)?.intValue ?? 0)
        }
    }
}
