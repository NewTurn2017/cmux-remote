import CryptoKit
import Foundation

struct AttachmentPreparer {
    private let securityScope: any AttachmentSecurityScope
    private let fileCoordinator: any AttachmentFileCoordinator
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    init(
        securityScope: any AttachmentSecurityScope = FoundationAttachmentSecurityScope(),
        fileCoordinator: any AttachmentFileCoordinator = FoundationAttachmentFileCoordinator(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-remote-attachments", isDirectory: true)
    ) {
        self.securityScope = securityScope
        self.fileCoordinator = fileCoordinator
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    func prepare(_ selections: [AttachmentSelection]) async throws -> [PreparedAttachment] {
        var stagedURLs: [URL] = []
        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            var prepared: [PreparedAttachment] = []
            let orderedSelections = selections.enumerated().map { (ordinal: $0.offset, selection: $0.element) }
            for item in orderedSelections {
                let ordinal = item.ordinal
                let selection = item.selection
                try Task.checkCancellation()
                let stagedURL = temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("partial")
                stagedURLs.append(stagedURL)
                let hasSecurityScope = await securityScope.startAccessingSecurityScopedResource(for: selection.url)
                do {
                    try Task.checkCancellation()
                    let bytes = try await fileCoordinator.copy(
                        from: selection.url,
                        to: stagedURL,
                        maximumBytes: AttachmentPreparationLimits.maxFileBytes
                    )
                    try Task.checkCancellation()
                    let digest = try Self.sha256(of: stagedURL, fileManager: fileManager)
                    let originalName = selection.url.lastPathComponent
                    let normalizedName = AttachmentName.normalized(originalName)
                    prepared.append(PreparedAttachment(
                        ordinal: ordinal,
                        filename: normalizedName,
                        mimeType: AttachmentMIME.type(filename: normalizedName, declared: selection.declaredMIMEType),
                        bytes: bytes,
                        sha256: digest,
                        stagedURL: stagedURL
                    ))
                } catch is CancellationError {
                    if hasSecurityScope { await securityScope.stopAccessingSecurityScopedResource(for: selection.url) }
                    throw AttachmentPreparationError.cancelled
                } catch let error as AttachmentPreparationError {
                    if hasSecurityScope { await securityScope.stopAccessingSecurityScopedResource(for: selection.url) }
                    throw error
                } catch {
                    if hasSecurityScope { await securityScope.stopAccessingSecurityScopedResource(for: selection.url) }
                    throw AttachmentPreparationError.stagingFailed
                }
                if hasSecurityScope { await securityScope.stopAccessingSecurityScopedResource(for: selection.url) }
            }
            return prepared
        } catch is CancellationError {
            Self.remove(stagedURLs, fileManager: fileManager)
            throw AttachmentPreparationError.cancelled
        } catch let error as AttachmentPreparationError {
            Self.remove(stagedURLs, fileManager: fileManager)
            throw error
        } catch {
            Self.remove(stagedURLs, fileManager: fileManager)
            throw AttachmentPreparationError.stagingFailed
        }
    }

    private static func remove(_ urls: [URL], fileManager: FileManager) {
        for url in urls { try? fileManager.removeItem(at: url) }
    }

    private static func sha256(of url: URL, fileManager: FileManager) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else { throw AttachmentPreparationError.stagingFailed }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AttachmentPreparationError.stagingFailed
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class FoundationAttachmentSecurityScope: AttachmentSecurityScope {
    func startAccessingSecurityScopedResource(for url: URL) async -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessingSecurityScopedResource(for url: URL) async {
        url.stopAccessingSecurityScopedResource()
    }
}

final class FoundationAttachmentFileCoordinator: AttachmentFileCoordinator {
    private let fileManager: FileManager
    private let partialObserver: (any AttachmentPartialCreationObserver)?

    init(
        fileManager: FileManager = .default,
        partialObserver: (any AttachmentPartialCreationObserver)? = nil
    ) {
        self.fileManager = fileManager
        self.partialObserver = partialObserver
    }

    func copy(from source: URL, to destination: URL, maximumBytes: Int64) async throws -> Int64 {
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw AttachmentPreparationError.stagingFailed
        }
        if let partialObserver {
            await partialObserver.partialCreated(at: destination)
        }
        var coordinationError: NSError?
        var copyError: Error?
        var copiedBytes: Int64?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
            do {
                copiedBytes = try streamCopy(
                    from: readableURL,
                    to: destination,
                    maximumBytes: maximumBytes
                )
            } catch {
                copyError = error
            }
        }
        if let copyError { throw copyError }
        if coordinationError != nil || copiedBytes == nil {
            throw AttachmentPreparationError.sourceUnavailable
        }
        return copiedBytes!
    }

    private func streamCopy(from source: URL, to destination: URL, maximumBytes: Int64) throws -> Int64 {
        let input: FileHandle
        let output: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
            output = try FileHandle(forWritingTo: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw AttachmentPreparationError.sourceUnavailable
        }
        defer {
            try? input.close()
            try? output.close()
        }
        var total: Int64 = 0
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            let nextTotal = total + Int64(chunk.count)
            guard nextTotal <= maximumBytes else {
                throw AttachmentPreparationError.fileTooLarge
            }
            try output.write(contentsOf: chunk)
            total = nextTotal
        }
        return total
    }
}
