import Crypto
import Darwin
import Foundation
import RelayCore
import SharedKit

/// Stores authenticated, resumable file uploads and atomically commits verified files.
public actor ChunkedFileUploadService {
    /// The maximum decoded size accepted by one chunk.
    public static let maxChunkBytes = ChunkUploadLimits.rawChunkBytes
    /// The maximum declared size accepted for one file.
    public static let maxFileBytes = Int64(ChunkUploadLimits.maxFileBytes)
    /// The maximum number of files accepted in one batch.
    public static let maxBatchFiles = ChunkUploadLimits.maxBatchFiles
    /// The maximum declared bytes accepted in one batch.
    public static let maxBatchBytes = Int64(ChunkUploadLimits.maxBatchBytes)
    /// The maximum number of temporary uploads held open at once.
    public static let maxConcurrentUploads = ChunkUploadLimits.maxBatchFiles
    /// The inactivity interval after which temporary state is removed.
    public static let abandonedUploadTTL = TimeInterval(ChunkUploadLimits.abandonedUploadTTLSeconds)

    /// A deadline scheduler whose returned task is retained and cancelled with the service lifecycle.
    public typealias CleanupScheduler = @Sendable (
        _ delay: TimeInterval,
        _ action: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never>

    /// A narrow test seam immediately before a verified directory descriptor creates or renames a child.
    public enum FilesystemCheckpoint: Equatable, Sendable {
        /// The root and staging descriptors are open and verified, but the `.part` file does not exist yet.
        case beforeTemporaryFileCreate
        /// File verification, fsync, and close completed, but the atomic destination rename has not run.
        case beforeAtomicRename
    }

    /// The resumable state returned by ``begin(authenticatedDeviceID:uploadID:batchID:batchFileCount:batchBytes:filename:mimeType:declaredBytes:sha256:)``.
    public struct BeginState: Equatable, Sendable {
        /// The canonical process-lifetime upload identifier.
        public let uploadID: String
        /// The normalized filename used for the eventual destination.
        public let filename: String
        /// The normalized MIME type used for the eventual result.
        public let mimeType: String
        /// The next byte offset expected by ``chunk(authenticatedDeviceID:uploadID:offset:dataBase64:)``.
        public let offset: Int64
        /// The already-committed result when this identifier completed earlier.
        public let result: CommittedUpload?
    }

    /// Metadata for a file that passed size and SHA-256 verification and was atomically committed.
    public struct CommittedUpload: Equatable, Sendable {
        /// The canonical upload identifier.
        public let uploadID: String
        /// The collision-free timestamped destination filename.
        public let filename: String
        /// The absolute destination path.
        public let path: String
        /// The verified number of bytes.
        public let bytes: Int64
        /// The normalized MIME type.
        public let mimeType: String
        /// The verified lowercase SHA-256 digest.
        public let sha256: String
    }

    /// A stable service failure that relay RPC wiring can map to a structured error response.
    public struct ServiceError: Error, Equatable, Sendable, CustomStringConvertible {
        /// The machine-readable failure code.
        public let code: String
        /// The human-readable failure detail.
        public let message: String

        /// The failure detail suitable for diagnostics that do not contain file content.
        public var description: String { "\(code): \(message)" }
    }

    private struct Metadata: Equatable {
        let deviceID: String
        let batchID: String
        let batchFileCount: Int
        let batchBytes: Int64
        let filename: String
        let mimeType: String
        let declaredBytes: Int64
        let sha256: String
    }

    private struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    // Owns C directory resources exclusively; actor isolation prevents concurrent use, and deinit closes each immutable handle once.
    final class OrphanScanResources: @unchecked Sendable {
        let rootDescriptor: Int32
        let uploadsDescriptor: Int32
        let directory: UnsafeMutablePointer<DIR>

        init(
            rootDescriptor: Int32,
            uploadsDescriptor: Int32,
            directory: UnsafeMutablePointer<DIR>
        ) {
            self.rootDescriptor = rootDescriptor
            self.uploadsDescriptor = uploadsDescriptor
            self.directory = directory
        }

        deinit {
            Darwin.closedir(directory)
            _ = Darwin.close(uploadsDescriptor)
            _ = Darwin.close(rootDescriptor)
        }
    }

    private struct ActiveUpload {
        let metadata: Metadata
        let tempFilename: String
        let handle: FileHandle
        let rootDescriptor: Int32
        let uploadsDescriptor: Int32
        let rootIdentity: DirectoryIdentity
        let uploadsIdentity: DirectoryIdentity
        var receivedBytes: Int64
        var hasher: SHA256
        var lastActivity: TimeInterval
    }

    private struct CompletedRecord {
        let metadata: Metadata
        let result: CommittedUpload
    }

    private struct BatchKey: Hashable {
        let deviceID: String
        let batchID: String
    }

    private struct BatchUsage {
        let declaredFileCount: Int
        let declaredBytes: Int64
        var files: Int
        var bytes: Int64
    }

    private let rootURL: URL
    private let clock: any Clock
    private let uuidSource: @Sendable () -> UUID
    private let cleanupScheduler: CleanupScheduler
    private let filesystemCheckpoint: @Sendable (FilesystemCheckpoint) -> Void
    private var activeUploads: [String: ActiveUpload] = [:]
    private var completedUploads: [String: CompletedRecord] = [:]
    private var completedUploadOrder: [String] = []
    private var orphanCleanupTask: Task<Void, Never>?
    private var orphanCleanupGeneration: UUID?
    private var orphanScanResources: OrphanScanResources?
    private var orphanScanRootIdentity: DirectoryIdentity?
    private var orphanScanUploadsIdentity: DirectoryIdentity?
    private var orphanScanEarliestDeadline: TimeInterval?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupGeneration: UUID?

    /// Creates a chunked upload service with injectable filesystem identity and time seams.
    ///
    /// The default root is `~/Downloads/cmux-remote`. Tests should always provide a temporary
    /// root, a fake ``Clock``, and a scheduler they can trigger directly.
    ///
    /// - Parameters:
    ///   - rootURL: Destination directory that owns the private `.uploads` staging directory.
    ///   - clock: Source of timestamps and abandoned-upload age.
    ///   - uuidSource: Source of unguessable temporary filenames.
    ///   - cleanupScheduler: Deadline scheduler for bounded startup orphans and current actor-owned state.
    ///   - filesystemCheckpoint: Synchronous test seam around descriptor-anchored child operations.
    public init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("cmux-remote", isDirectory: true),
        clock: any Clock = SystemClock(),
        uuidSource: @escaping @Sendable () -> UUID = { UUID() },
        cleanupScheduler: @escaping CleanupScheduler = { delay, action in
            Task {
                let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
                // This bounded sleep is the intended abandoned-upload deadline; tests inject a scheduler.
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await action()
            }
        },
        filesystemCheckpoint: @escaping @Sendable (FilesystemCheckpoint) -> Void = { _ in }
    ) {
        // Preserve the caller's lexical components; Foundation standardization may follow existing symlinks.
        self.rootURL = rootURL
        self.clock = clock
        self.uuidSource = uuidSource
        self.cleanupScheduler = cleanupScheduler
        self.filesystemCheckpoint = filesystemCheckpoint
        let generation = UUID()
        orphanCleanupGeneration = generation
        _ = cleanupScheduler(0) { [weak self] in
            await self?.runOrphanCleanupSlice(generation: generation)
        }
    }

    deinit {
        orphanCleanupTask?.cancel()
        cleanupTask?.cancel()
    }

    /// Begins a new upload or resumes an identical process-lifetime identifier.
    ///
    /// Filename and MIME metadata are normalized again at this trust boundary. The upload is
    /// device-scoped, and all declarations are validated before the destination or staging
    /// directories are created.
    ///
    /// - Parameters:
    ///   - authenticatedDeviceID: Nonempty identity established by relay authentication.
    ///   - uploadID: Client-generated UUID used for idempotency and resume.
    ///   - batchID: Stable client-generated batch identity used across connections and retries.
    ///   - batchFileCount: Declared number of files in the complete batch, from one through ``maxBatchFiles``; defaults to the maximum for direct service callers.
    ///   - batchBytes: Declared aggregate bytes in the complete batch, through ``maxBatchBytes``; defaults to the maximum for direct service callers.
    ///   - filename: Untrusted requested filename.
    ///   - mimeType: Untrusted declared MIME type.
    ///   - declaredBytes: Expected byte count, from zero through ``maxFileBytes``.
    ///   - sha256: Expected 64-character hexadecimal SHA-256 digest.
    /// - Returns: Current offset, or the previous committed result for an identical identifier.
    /// - Throws: ``ServiceError`` when authentication, metadata, limits, or storage validation fails.
    public func begin(
        authenticatedDeviceID: String,
        uploadID: String,
        batchID: String,
        batchFileCount: Int = ChunkedFileUploadService.maxBatchFiles,
        batchBytes: Int64 = ChunkedFileUploadService.maxBatchBytes,
        filename: String,
        mimeType: String,
        declaredBytes: Int64,
        sha256: String
    ) throws -> BeginState {
        let deviceID = try Self.validatedDeviceID(authenticatedDeviceID)
        let canonicalUploadID = try Self.canonicalUploadID(uploadID)
        let canonicalBatchID = try Self.validatedBatchID(batchID)
        guard (1...Self.maxBatchFiles).contains(batchFileCount) else {
            throw Self.error("invalid_batch_file_count", "Batch file count must be from 1 through \(Self.maxBatchFiles)")
        }
        guard batchBytes >= 0, batchBytes <= Self.maxBatchBytes else {
            throw Self.error("invalid_batch_bytes", "Batch bytes must be from 0 through \(Self.maxBatchBytes)")
        }
        guard declaredBytes >= 0 else {
            throw Self.error("invalid_size", "Declared bytes must not be negative")
        }
        guard declaredBytes <= Self.maxFileBytes else {
            throw Self.error("file_too_large", "Declared bytes exceed \(Self.maxFileBytes)")
        }
        guard declaredBytes <= batchBytes else {
            throw Self.error("batch_too_large", "File bytes exceed the declared batch bytes")
        }
        let canonicalHash = try Self.validatedSHA256(sha256)
        var normalizedFilename = Self.normalizedFilename(filename)
        var normalizedMIME = Self.normalizedMIMEType(mimeType, filename: normalizedFilename)
        if (normalizedFilename as NSString).pathExtension.isEmpty,
           normalizedMIME == "application/octet-stream"
        {
            normalizedFilename = "attachment.bin"
            normalizedMIME = Self.normalizedMIMEType(mimeType, filename: normalizedFilename)
        }
        let metadata = Metadata(
            deviceID: deviceID,
            batchID: canonicalBatchID,
            batchFileCount: batchFileCount,
            batchBytes: batchBytes,
            filename: normalizedFilename,
            mimeType: normalizedMIME,
            declaredBytes: declaredBytes,
            sha256: canonicalHash
        )

        if var active = activeUploads[canonicalUploadID] {
            guard active.metadata.deviceID == deviceID else {
                throw Self.error("device_scope_mismatch", "Upload belongs to another authenticated device")
            }
            guard active.metadata == metadata else {
                throw Self.error("upload_conflict", "Upload identifier was declared with different metadata")
            }
            active.lastActivity = clock.now
            activeUploads[canonicalUploadID] = active
            return BeginState(
                uploadID: canonicalUploadID,
                filename: metadata.filename,
                mimeType: metadata.mimeType,
                offset: active.receivedBytes,
                result: nil
            )
        }
        if let completed = completedUploads[canonicalUploadID] {
            guard completed.metadata.deviceID == deviceID else {
                throw Self.error("device_scope_mismatch", "Upload belongs to another authenticated device")
            }
            guard completed.metadata == metadata else {
                throw Self.error("upload_conflict", "Upload identifier was declared with different metadata")
            }
            return BeginState(
                uploadID: canonicalUploadID,
                filename: metadata.filename,
                mimeType: metadata.mimeType,
                offset: metadata.declaredBytes,
                result: completed.result
            )
        }

        let batchKey = BatchKey(deviceID: deviceID, batchID: canonicalBatchID)
        let usage = try derivedBatchUsage(for: batchKey) ?? BatchUsage(
            declaredFileCount: batchFileCount,
            declaredBytes: batchBytes,
            files: 0,
            bytes: 0
        )
        guard usage.declaredFileCount == batchFileCount,
              usage.declaredBytes == batchBytes else {
            throw Self.error("batch_conflict", "Batch identifier was reused with different declared totals")
        }
        guard usage.files < usage.declaredFileCount else {
            throw Self.error("batch_file_limit", "Batch file limit is \(usage.declaredFileCount)")
        }
        guard declaredBytes <= usage.declaredBytes - usage.bytes else {
            throw Self.error("batch_too_large", "Batch bytes exceed \(usage.declaredBytes)")
        }
        guard activeUploads.count < Self.maxConcurrentUploads else {
            throw Self.error("too_many_uploads", "Concurrent upload limit is \(Self.maxConcurrentUploads)")
        }

        let temp = try reserveTemporaryFile()
        activeUploads[canonicalUploadID] = ActiveUpload(
            metadata: metadata,
            tempFilename: temp.filename,
            handle: temp.handle,
            rootDescriptor: temp.rootDescriptor,
            uploadsDescriptor: temp.uploadsDescriptor,
            rootIdentity: temp.rootIdentity,
            uploadsIdentity: temp.uploadsIdentity,
            receivedBytes: 0,
            hasher: SHA256(),
            lastActivity: clock.now
        )
        scheduleNextCleanupIfNeeded()
        return BeginState(
            uploadID: canonicalUploadID,
            filename: metadata.filename,
            mimeType: metadata.mimeType,
            offset: 0,
            result: nil
        )
    }

    /// Appends one canonical base64 chunk at the exact expected offset.
    ///
    /// Only the bounded decoded chunk is resident in memory. Bytes are appended directly to the
    /// temporary file and fed into the incremental SHA-256 state.
    ///
    /// - Parameters:
    ///   - authenticatedDeviceID: Authenticated identity that began the upload.
    ///   - uploadID: Existing upload UUID.
    ///   - offset: Exact current byte offset.
    ///   - dataBase64: Canonical base64 for one nonempty chunk no larger than ``maxChunkBytes``.
    /// - Returns: The offset expected for the next chunk.
    /// - Throws: ``ServiceError`` for stale IDs, scope violations, malformed chunks, or I/O failures.
    public func chunk(
        authenticatedDeviceID: String,
        uploadID: String,
        offset: Int64,
        dataBase64: String
    ) throws -> Int64 {
        let deviceID = try Self.validatedDeviceID(authenticatedDeviceID)
        let canonicalUploadID = try Self.canonicalUploadID(uploadID)
        if let completed = completedUploads[canonicalUploadID] {
            guard completed.metadata.deviceID == deviceID else {
                throw Self.error("device_scope_mismatch", "Upload belongs to another authenticated device")
            }
            throw Self.error("already_committed", "Upload has already been committed")
        }
        guard var active = activeUploads[canonicalUploadID] else {
            throw Self.error("upload_not_found", "Upload identifier is stale or unknown")
        }
        guard active.metadata.deviceID == deviceID else {
            throw Self.error("device_scope_mismatch", "Upload belongs to another authenticated device")
        }
        guard offset == active.receivedBytes else {
            throw Self.error("offset_conflict", "Expected offset \(active.receivedBytes)")
        }

        let canonicalBase64Characters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
        )
        guard dataBase64.unicodeScalars.allSatisfy(canonicalBase64Characters.contains) else {
            throw Self.error("invalid_base64", "Chunk must use canonical base64")
        }
        let maximumEncodedBytes = ((Self.maxChunkBytes + 2) / 3) * 4
        guard dataBase64.utf8.count <= maximumEncodedBytes else {
            throw Self.error("chunk_too_large", "Decoded chunk exceeds \(Self.maxChunkBytes)")
        }
        guard let bytes = Data(base64Encoded: dataBase64),
              !bytes.isEmpty,
              bytes.base64EncodedString() == dataBase64
        else {
            throw Self.error("invalid_base64", "Chunk must use canonical base64")
        }
        guard bytes.count <= Self.maxChunkBytes else {
            throw Self.error("chunk_too_large", "Decoded chunk exceeds \(Self.maxChunkBytes)")
        }
        guard Int64(bytes.count) <= active.metadata.declaredBytes - active.receivedBytes else {
            throw Self.error("size_mismatch", "Chunk exceeds the declared file size")
        }

        do {
            try active.handle.write(contentsOf: bytes)
        } catch {
            discardActiveUpload(canonicalUploadID)
            throw Self.error("write_failed", "Temporary file write failed: \(error)")
        }
        active.hasher.update(data: bytes)
        active.receivedBytes += Int64(bytes.count)
        active.lastActivity = clock.now
        activeUploads[canonicalUploadID] = active
        return active.receivedBytes
    }

    /// Verifies, fsyncs, closes, and atomically moves one complete upload into its final path.
    ///
    /// Existing names are compared case-insensitively and are never overwritten. A collision
    /// receives `-2`, `-3`, and subsequent suffixes before the extension.
    ///
    /// - Parameters:
    ///   - authenticatedDeviceID: Authenticated identity that began the upload.
    ///   - uploadID: Existing upload UUID.
    /// - Returns: Approved metadata for the atomically committed file.
    /// - Throws: ``ServiceError`` when size, hash, scope, or filesystem guarantees fail.
    public func commit(
        authenticatedDeviceID: String,
        uploadID: String
    ) throws -> CommittedUpload {
        let deviceID = try Self.validatedDeviceID(authenticatedDeviceID)
        let canonicalUploadID = try Self.canonicalUploadID(uploadID)
        if let completed = completedUploads[canonicalUploadID] {
            guard completed.metadata.deviceID == deviceID else {
                throw Self.error("device_scope_mismatch", "Upload belongs to another authenticated device")
            }
            return completed.result
        }
        guard let active = activeUploads[canonicalUploadID] else {
            throw Self.error("upload_not_found", "Upload identifier is stale or unknown")
        }
        guard active.metadata.deviceID == deviceID else {
            throw Self.error("device_scope_mismatch", "Upload belongs to another authenticated device")
        }
        guard active.receivedBytes == active.metadata.declaredBytes else {
            discardActiveUpload(canonicalUploadID)
            throw Self.error(
                "size_mismatch",
                "Received \(active.receivedBytes) of \(active.metadata.declaredBytes) declared bytes"
            )
        }
        let finalHasher = active.hasher
        let actualHash = finalHasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualHash == active.metadata.sha256 else {
            discardActiveUpload(canonicalUploadID)
            throw Self.error("hash_mismatch", "Uploaded bytes do not match the declared SHA-256")
        }

        guard Darwin.fsync(active.handle.fileDescriptor) == 0 else {
            let detail = String(cString: strerror(errno))
            discardActiveUpload(canonicalUploadID)
            throw Self.error("write_failed", "Temporary file fsync failed: \(detail)")
        }
        do {
            try active.handle.close()
        } catch {
            discardActiveUpload(canonicalUploadID)
            throw Self.error("write_failed", "Temporary file close failed: \(error)")
        }

        activeUploads.removeValue(forKey: canonicalUploadID)
        cancelCleanupIfIdle()
        do {
            let destination = try moveWithoutOverwrite(
                active: active,
                normalizedFilename: active.metadata.filename
            )
            closeStagingDescriptors(active, removeTemporary: false)
            let result = CommittedUpload(
                uploadID: canonicalUploadID,
                filename: destination.lastPathComponent,
                path: destination.path,
                bytes: active.receivedBytes,
                mimeType: active.metadata.mimeType,
                sha256: actualHash
            )
            completedUploads[canonicalUploadID] = CompletedRecord(metadata: active.metadata, result: result)
            completedUploadOrder.append(canonicalUploadID)
            return result
        } catch let error as ServiceError {
            closeStagingDescriptors(active, removeTemporary: true)
            throw error
        } catch {
            closeStagingDescriptors(active, removeTemporary: true)
            throw Self.error("write_failed", "Atomic commit failed: \(error)")
        }
    }

    /// Returns the newest committed files uploaded by one authenticated device.
    ///
    /// These paths are server-minted results, not client-provided scan input. The artifact
    /// service can therefore safely authorize them for the same device without exposing
    /// arbitrary host paths or another device's uploads.
    func recentCommittedUploads(
        authenticatedDeviceID: String,
        limit: Int = 200
    ) throws -> [CommittedUpload] {
        let deviceID = try Self.validatedDeviceID(authenticatedDeviceID)
        guard limit > 0 else { return [] }
        let boundedLimit = min(limit, 200)
        var results: [CommittedUpload] = []
        results.reserveCapacity(min(boundedLimit, completedUploads.count))
        for uploadID in completedUploadOrder.reversed() {
            guard results.count < boundedLimit else { break }
            guard let completed = completedUploads[uploadID],
                  completed.metadata.deviceID == deviceID
            else { continue }
            results.append(completed.result)
        }
        return results
    }

    /// The number of standalone batch-accounting entries retained by the service.
    func retainedBatchUsageCount() -> Int {
        0
    }

    /// Cancels an active upload and removes its temporary bytes.
    ///
    /// Unknown, already-cancelled, and already-committed identifiers are successful no-ops.
    /// Committed destination files are never removed by cancellation.
    ///
    /// - Parameters:
    ///   - authenticatedDeviceID: Authenticated identity that owns the upload, when it exists.
    ///   - uploadID: Upload UUID to cancel.
    /// - Throws: ``ServiceError`` for malformed IDs or a known upload owned by another device.
    public func cancel(
        authenticatedDeviceID: String,
        uploadID: String
    ) throws {
        let deviceID = try Self.validatedDeviceID(authenticatedDeviceID)
        let canonicalUploadID = try Self.canonicalUploadID(uploadID)
        if let active = activeUploads[canonicalUploadID] {
            guard active.metadata.deviceID == deviceID else {
                throw Self.error("device_scope_mismatch", "Upload belongs to another authenticated device")
            }
            discardActiveUpload(canonicalUploadID)
            return
        }
        if let completed = completedUploads[canonicalUploadID], completed.metadata.deviceID != deviceID {
            throw Self.error("device_scope_mismatch", "Upload belongs to another authenticated device")
        }
    }

    private func reserveTemporaryFile() throws -> (
        filename: String,
        handle: FileHandle,
        rootDescriptor: Int32,
        uploadsDescriptor: Int32,
        rootIdentity: DirectoryIdentity,
        uploadsIdentity: DirectoryIdentity
    ) {
        guard let staging = try openVerifiedStagingDirectories(createMissing: true) else {
            throw Self.error("write_failed", "Upload staging directories could not be created")
        }
        do {
            filesystemCheckpoint(.beforeTemporaryFileCreate)
            try validatePathIdentity(
                root: staging.rootIdentity,
                uploads: staging.uploadsIdentity
            )

            for _ in 0..<16 {
                let filename = uuidSource().uuidString.lowercased() + ".part"
                try validatePathIdentity(
                    root: staging.rootIdentity,
                    uploads: staging.uploadsIdentity
                )
                let descriptor = filename.withCString {
                    Darwin.openat(
                        staging.uploadsDescriptor,
                        $0,
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        mode_t(0o600)
                    )
                }
                if descriptor >= 0 {
                    do {
                        try validatePathIdentity(
                            root: staging.rootIdentity,
                            uploads: staging.uploadsIdentity
                        )
                    } catch {
                        _ = filename.withCString { Darwin.unlinkat(staging.uploadsDescriptor, $0, 0) }
                        _ = Darwin.close(descriptor)
                        throw error
                    }
                    return (
                        filename,
                        FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
                        staging.rootDescriptor,
                        staging.uploadsDescriptor,
                        staging.rootIdentity,
                        staging.uploadsIdentity
                    )
                }
                if errno != EEXIST {
                    throw Self.error(
                        "write_failed",
                        "Temporary file creation failed: \(String(cString: strerror(errno)))"
                    )
                }
            }
            throw Self.error("write_failed", "Could not reserve a unique temporary filename")
        } catch {
            closeStagingDirectories(
                rootDescriptor: staging.rootDescriptor,
                uploadsDescriptor: staging.uploadsDescriptor,
                rootIdentity: staging.rootIdentity,
                uploadsIdentity: staging.uploadsIdentity
            )
            throw error
        }
    }

    private func openVerifiedStagingDirectories(createMissing: Bool) throws -> (
        rootDescriptor: Int32,
        uploadsDescriptor: Int32,
        rootIdentity: DirectoryIdentity,
        uploadsIdentity: DirectoryIdentity
    )? {
        guard let root = try securelyOpenRoot(
            createMissing: createMissing,
            enforcePrivatePermissions: true
        ) else { return nil }
        do {
            if createMissing {
                let makeResult = ".uploads".withCString {
                    Darwin.mkdirat(root.descriptor, $0, mode_t(0o700))
                }
                guard makeResult == 0 || errno == EEXIST else {
                    throw Self.error("write_failed", "Staging directory creation failed")
                }
            }

            let uploadsDescriptor = ".uploads".withCString {
                Darwin.openat(
                    root.descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            if uploadsDescriptor < 0, !createMissing, errno == ENOENT {
                _ = Darwin.close(root.descriptor)
                return nil
            }
            guard uploadsDescriptor >= 0 else {
                let code = errno == ELOOP || errno == ENOTDIR ? "symlink_root" : "write_failed"
                throw Self.error(code, "Staging directory could not be opened without following links")
            }
            do {
                var uploadsInfo = stat()
                guard Darwin.fstat(uploadsDescriptor, &uploadsInfo) == 0,
                      (uploadsInfo.st_mode & S_IFMT) == S_IFDIR
                else {
                    throw Self.error("symlink_root", "Staging directory is not stable")
                }
                guard Darwin.fchmod(uploadsDescriptor, mode_t(0o700)) == 0 else {
                    throw Self.error("write_failed", "Staging directory permission update failed")
                }
                let uploadsIdentity = Self.directoryIdentity(uploadsInfo)
                try validatePathIdentity(root: root.identity, uploads: uploadsIdentity)
                return (
                    root.descriptor,
                    uploadsDescriptor,
                    root.identity,
                    uploadsIdentity
                )
            } catch {
                _ = Darwin.close(uploadsDescriptor)
                throw error
            }
        } catch {
            _ = Darwin.close(root.descriptor)
            throw error
        }
    }

    private func securelyOpenRoot(
        createMissing: Bool,
        enforcePrivatePermissions: Bool
    ) throws -> (descriptor: Int32, identity: DirectoryIdentity)? {
        guard rootURL.isFileURL,
              rootURL.path.hasPrefix("/"),
              rootURL.pathComponents.first == "/"
        else {
            throw Self.error("symlink_root", "Upload root must be an absolute file path")
        }

        var currentDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard currentDescriptor >= 0 else {
            throw Self.error("write_failed", "Filesystem root could not be opened")
        }

        do {
            let components = rootURL.pathComponents.dropFirst()
            guard !components.isEmpty else {
                throw Self.error("symlink_root", "Filesystem root cannot be the upload destination")
            }
            for component in components {
                guard !component.isEmpty,
                      component != ".",
                      component != "..",
                      !component.contains("/"),
                      !component.utf8.contains(0)
                else {
                    throw Self.error("symlink_root", "Upload root contains an invalid path component")
                }

                var childDescriptor = component.withCString {
                    Darwin.openat(
                        currentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                if childDescriptor < 0, errno == ENOENT {
                    if !createMissing {
                        _ = Darwin.close(currentDescriptor)
                        return nil
                    }
                    let makeResult = component.withCString {
                        Darwin.mkdirat(currentDescriptor, $0, mode_t(0o700))
                    }
                    guard makeResult == 0 || errno == EEXIST else {
                        throw Self.error("write_failed", "Upload root directory creation failed")
                    }
                    childDescriptor = component.withCString {
                        Darwin.openat(
                            currentDescriptor,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                }
                guard childDescriptor >= 0 else {
                    let code = errno == ELOOP || errno == ENOTDIR ? "symlink_root" : "write_failed"
                    throw Self.error(code, "Upload root component could not be opened without following links")
                }

                var childInfo = stat()
                guard Darwin.fstat(childDescriptor, &childInfo) == 0,
                      (childInfo.st_mode & S_IFMT) == S_IFDIR
                else {
                    _ = Darwin.close(childDescriptor)
                    throw Self.error("symlink_root", "Upload root component is not a stable directory")
                }
                _ = Darwin.close(currentDescriptor)
                currentDescriptor = childDescriptor
            }

            var rootInfo = stat()
            guard Darwin.fstat(currentDescriptor, &rootInfo) == 0,
                  (rootInfo.st_mode & S_IFMT) == S_IFDIR
            else {
                throw Self.error("symlink_root", "Upload root is not a stable directory")
            }
            if enforcePrivatePermissions,
               Darwin.fchmod(currentDescriptor, mode_t(0o700)) != 0
            {
                throw Self.error("write_failed", "Upload root permission update failed")
            }
            return (currentDescriptor, Self.directoryIdentity(rootInfo))
        } catch {
            _ = Darwin.close(currentDescriptor)
            throw error
        }
    }

    private func moveWithoutOverwrite(
        active: ActiveUpload,
        normalizedFilename: String
    ) throws -> URL {
        try validatePathIdentity(root: active.rootIdentity, uploads: active.uploadsIdentity)
        filesystemCheckpoint(.beforeAtomicRename)
        try validatePathIdentity(root: active.rootIdentity, uploads: active.uploadsIdentity)

        let timestamp = Self.timestamp(clock.now)
        let requested = "\(timestamp)-\(normalizedFilename)"
        let extensionPart = (requested as NSString).pathExtension
        let stem = (requested as NSString).deletingPathExtension
        let existing = try Self.directoryNames(descriptor: active.rootDescriptor)
            .filter { $0 != ".uploads" }
            .reduce(into: Set<String>()) { names, name in
                names.insert(name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")))
            }

        var suffix = 1
        while suffix < Int.max {
            let candidateName: String
            if suffix == 1 {
                candidateName = requested
            } else if extensionPart.isEmpty {
                candidateName = "\(stem)-\(suffix)"
            } else {
                candidateName = "\(stem)-\(suffix).\(extensionPart)"
            }
            suffix += 1
            let folded = candidateName.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if existing.contains(folded) { continue }

            try validatePathIdentity(root: active.rootIdentity, uploads: active.uploadsIdentity)
            let result = active.tempFilename.withCString { sourceName in
                candidateName.withCString { destinationName in
                    Darwin.renameatx_np(
                        active.uploadsDescriptor,
                        sourceName,
                        active.rootDescriptor,
                        destinationName,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if result == 0 {
                do {
                    try validatePathIdentity(root: active.rootIdentity, uploads: active.uploadsIdentity)
                    guard candidateName.withCString({
                        Darwin.fchmodat(active.rootDescriptor, $0, mode_t(0o600), 0)
                    }) == 0 else {
                        throw Self.error("write_failed", "Destination permission update failed")
                    }
                    guard Darwin.fsync(active.rootDescriptor) == 0 else {
                        throw Self.error("write_failed", "Destination directory fsync failed")
                    }
                    return rootURL.appendingPathComponent(candidateName, isDirectory: false)
                } catch {
                    _ = candidateName.withCString { Darwin.unlinkat(active.rootDescriptor, $0, 0) }
                    throw error
                }
            }
            if errno == EEXIST { continue }
            throw Self.error("write_failed", "Atomic rename failed: \(String(cString: strerror(errno)))")
        }
        throw Self.error("write_failed", "Could not choose a collision-free destination")
    }

    private func discardActiveUpload(_ uploadID: String) {
        guard let active = activeUploads.removeValue(forKey: uploadID) else { return }
        try? active.handle.close()
        closeStagingDescriptors(active, removeTemporary: true)
        cancelCleanupIfIdle()
    }

    private func derivedBatchUsage(for key: BatchKey) throws -> BatchUsage? {
        var declaration: (fileCount: Int, bytes: Int64)?
        var files = 0
        var bytes: Int64 = 0
        let metadata = activeUploads.values.map(\.metadata)
            + completedUploads.values.map(\.metadata)

        for item in metadata where item.deviceID == key.deviceID && item.batchID == key.batchID {
            if let declaration {
                guard declaration.fileCount == item.batchFileCount,
                      declaration.bytes == item.batchBytes else {
                    throw Self.error("batch_conflict", "Batch identifier has inconsistent declarations")
                }
            } else {
                declaration = (item.batchFileCount, item.batchBytes)
            }
            files += 1
            bytes += item.declaredBytes
        }
        guard let declaration else { return nil }
        return BatchUsage(
            declaredFileCount: declaration.fileCount,
            declaredBytes: declaration.bytes,
            files: files,
            bytes: bytes
        )
    }

    private func closeStagingDescriptors(_ active: ActiveUpload, removeTemporary: Bool) {
        var removalFailed = false
        if removeTemporary {
            let result = active.tempFilename.withCString {
                Darwin.unlinkat(active.uploadsDescriptor, $0, 0)
            }
            removalFailed = result != 0 && errno != ENOENT
        }
        closeStagingDirectories(
            rootDescriptor: active.rootDescriptor,
            uploadsDescriptor: active.uploadsDescriptor,
            rootIdentity: active.rootIdentity,
            uploadsIdentity: active.uploadsIdentity
        )
        if removalFailed {
            scheduleOrphanCleanup(after: 0)
        }
    }

    private func closeStagingDirectories(
        rootDescriptor: Int32,
        uploadsDescriptor: Int32,
        rootIdentity: DirectoryIdentity,
        uploadsIdentity: DirectoryIdentity
    ) {
        _ = Darwin.close(uploadsDescriptor)
        if orphanScanResources == nil {
            _ = ".uploads".withCString {
                Darwin.unlinkat(rootDescriptor, $0, AT_REMOVEDIR)
            }
        }
        _ = Darwin.close(rootDescriptor)
    }

    private func scheduleOrphanCleanup(after delay: TimeInterval) {
        guard orphanCleanupTask == nil, orphanCleanupGeneration == nil else { return }
        let generation = UUID()
        orphanCleanupGeneration = generation
        orphanCleanupTask = cleanupScheduler(max(0, delay)) { [weak self] in
            await self?.runOrphanCleanupSlice(generation: generation)
        }
    }

    private func runOrphanCleanupSlice(generation: UUID) {
        guard orphanCleanupGeneration == generation else { return }
        orphanCleanupTask = nil
        orphanCleanupGeneration = nil

        do {
            guard try openOrphanScanIfNeeded() else { return }
            guard let resources = orphanScanResources,
                  let rootIdentity = orphanScanRootIdentity,
                  let uploadsIdentity = orphanScanUploadsIdentity
            else {
                closeOrphanScan()
                return
            }

            let activeNames = Set(activeUploads.values.map(\.tempFilename))
            var inspectedEntries = 0
            while inspectedEntries < Self.maxConcurrentUploads {
                guard let entry = Darwin.readdir(resources.directory) else {
                    finishOrphanScan()
                    return
                }
                let name = Self.directoryEntryName(entry)
                if name == "." || name == ".." { continue }
                inspectedEntries += 1
                guard !activeNames.contains(name),
                      name.hasSuffix(".part")
                else { continue }
                let uuidText = String(name.dropLast(".part".count))
                guard let uuid = UUID(uuidString: uuidText),
                      uuid.uuidString.lowercased() == uuidText
                else { continue }

                var info = stat()
                let status = name.withCString {
                    Darwin.fstatat(resources.uploadsDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
                }
                guard status == 0,
                      (info.st_mode & S_IFMT) == S_IFREG,
                      info.st_uid == geteuid()
                else { continue }

                let modified = TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
                let deadline = modified + Self.abandonedUploadTTL
                if deadline <= clock.now {
                    try validatePathIdentity(root: rootIdentity, uploads: uploadsIdentity)
                    _ = name.withCString { Darwin.unlinkat(resources.uploadsDescriptor, $0, 0) }
                } else if orphanScanEarliestDeadline == nil
                            || deadline < orphanScanEarliestDeadline!
                {
                    orphanScanEarliestDeadline = deadline
                }
            }
            scheduleOrphanCleanup(after: 0)
        } catch {
            closeOrphanScan()
        }
    }

    private func openOrphanScanIfNeeded() throws -> Bool {
        if orphanScanResources != nil { return true }
        guard let staging = try openVerifiedStagingDirectories(createMissing: false) else {
            return false
        }
        let duplicate = Darwin.dup(staging.uploadsDescriptor)
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            _ = Darwin.close(staging.uploadsDescriptor)
            _ = Darwin.close(staging.rootDescriptor)
            throw Self.error("write_failed", "Startup staging enumeration could not be anchored")
        }
        orphanScanResources = OrphanScanResources(
            rootDescriptor: staging.rootDescriptor,
            uploadsDescriptor: staging.uploadsDescriptor,
            directory: directory
        )
        orphanScanRootIdentity = staging.rootIdentity
        orphanScanUploadsIdentity = staging.uploadsIdentity
        orphanScanEarliestDeadline = nil
        return true
    }

    private func finishOrphanScan() {
        let deadline = orphanScanEarliestDeadline
        if deadline == nil, let resources = orphanScanResources {
            _ = ".uploads".withCString {
                Darwin.unlinkat(resources.rootDescriptor, $0, AT_REMOVEDIR)
            }
        }
        orphanScanResources = nil
        orphanScanRootIdentity = nil
        orphanScanUploadsIdentity = nil
        orphanScanEarliestDeadline = nil

        if let deadline {
            scheduleOrphanCleanup(after: deadline - clock.now)
        }
    }

    private func closeOrphanScan() {
        orphanScanResources = nil
        orphanScanRootIdentity = nil
        orphanScanUploadsIdentity = nil
        orphanScanEarliestDeadline = nil
    }

    private func scheduleNextCleanupIfNeeded() {
        guard cleanupTask == nil else { return }
        let deadlines = activeUploads.values.map { $0.lastActivity + Self.abandonedUploadTTL }
        guard let nextDeadline = deadlines.min() else { return }
        let generation = UUID()
        cleanupGeneration = generation
        cleanupTask = cleanupScheduler(max(0, nextDeadline - clock.now)) { [weak self] in
            await self?.runScheduledCleanup(generation: generation)
        }
    }

    private func runScheduledCleanup(generation: UUID) {
        guard cleanupGeneration == generation else { return }
        cleanupTask = nil
        cleanupGeneration = nil
        let now = clock.now
        let expired = activeUploads.compactMap { uploadID, active in
            now - active.lastActivity >= Self.abandonedUploadTTL ? uploadID : nil
        }
        for uploadID in expired {
            discardActiveUpload(uploadID)
        }
        scheduleNextCleanupIfNeeded()
    }

    private func cancelCleanupIfIdle() {
        guard activeUploads.isEmpty else { return }
        cleanupTask?.cancel()
        cleanupTask = nil
        cleanupGeneration = nil
    }

    private func validatePathIdentity(
        root expectedRoot: DirectoryIdentity,
        uploads expectedUploads: DirectoryIdentity? = nil
    ) throws {
        guard let root = try securelyOpenRoot(
            createMissing: false,
            enforcePrivatePermissions: false
        ), root.identity == expectedRoot else {
            throw Self.error("symlink_root", "Upload root identity changed during the operation")
        }
        defer { _ = Darwin.close(root.descriptor) }
        guard let expectedUploads else { return }

        let uploadsDescriptor = ".uploads".withCString {
            Darwin.openat(
                root.descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard uploadsDescriptor >= 0 else {
            throw Self.error("symlink_root", "Staging directory identity changed during the operation")
        }
        defer { _ = Darwin.close(uploadsDescriptor) }
        var uploadsInfo = stat()
        guard Darwin.fstat(uploadsDescriptor, &uploadsInfo) == 0,
              (uploadsInfo.st_mode & S_IFMT) == S_IFDIR,
              Self.directoryIdentity(uploadsInfo) == expectedUploads
        else {
            throw Self.error("symlink_root", "Staging directory identity changed during the operation")
        }
    }

    private static func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
    }

    private static func directoryNames(descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw Self.error("write_failed", "Directory enumeration could not be anchored")
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        while let entry = Darwin.readdir(directory) {
            let name = directoryEntryName(entry)
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    private static func directoryIdentity(_ info: stat) -> DirectoryIdentity {
        DirectoryIdentity(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino)
        )
    }

    private static func validatedDeviceID(_ deviceID: String) throws -> String {
        let trimmed = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw error("unauthenticated", "An authenticated device identity is required")
        }
        return trimmed
    }

    private static func canonicalUploadID(_ uploadID: String) throws -> String {
        guard let value = UUID(uuidString: uploadID) else {
            throw error("invalid_upload_id", "Upload identifier must be a UUID")
        }
        return value.uuidString.lowercased()
    }

    private static func validatedBatchID(_ batchID: String) throws -> String {
        let trimmed = batchID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == batchID,
              trimmed.utf8.count <= 128,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw error("invalid_batch_id", "Batch identifier is invalid")
        }
        return trimmed
    }

    private static func validatedSHA256(_ sha256: String) throws -> String {
        let lowered = sha256.lowercased()
        guard lowered.utf8.count == 64,
              lowered.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              })
        else {
            throw error("invalid_hash", "SHA-256 must be 64 hexadecimal characters")
        }
        return lowered
    }

    private static func normalizedFilename(_ requested: String) -> String {
        let slashNormalized = requested.replacingOccurrences(of: "\\", with: "/")
        let lastComponent = (slashNormalized as NSString).lastPathComponent
            .precomposedStringWithCanonicalMapping
        let forbiddenBidi: Set<UInt32> = [
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069,
        ]
        var sanitized = String.UnicodeScalarView()
        for scalar in lastComponent.unicodeScalars {
            if scalar == "/" || scalar == "\\" || scalar.value == 0
                || CharacterSet.controlCharacters.contains(scalar)
                || forbiddenBidi.contains(scalar.value)
            {
                sanitized.append("-")
            } else {
                sanitized.append(scalar)
            }
        }
        var value = String(sanitized).precomposedStringWithCanonicalMapping
        while value.first == "." { value.removeFirst() }
        value = value.replacingOccurrences(
            of: #"[\s.]+$"#,
            with: "",
            options: .regularExpression
        )
        guard !value.isEmpty else { return "attachment.bin" }

        let rawExtension = (value as NSString).pathExtension
        let extensionIsSafe = (1...16).contains(rawExtension.count)
            && rawExtension.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }
        let suffix = extensionIsSafe ? ".\(rawExtension)" : ""
        var stem = extensionIsSafe ? (value as NSString).deletingPathExtension : value
        let maximumStemBytes = max(1, 180 - suffix.utf8.count)
        while stem.utf8.count > maximumStemBytes, !stem.isEmpty {
            stem.removeLast()
        }
        while stem.last == "." || stem.last == " " { stem.removeLast() }
        if stem.isEmpty { stem = "attachment" }
        let normalized = stem + suffix
        if suffix.isEmpty, (normalized as NSString).pathExtension.isEmpty {
            return normalized == "attachment" ? "attachment.bin" : normalized
        }
        return normalized
    }

    private static func normalizedMIMEType(_ declared: String, filename: String) -> String {
        let knownByExtension: [String: String] = [
            "pdf": "application/pdf",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "hwp": "application/x-hwp",
            "hwpx": "application/vnd.hancom.hwpx",
            "zip": "application/zip",
            "png": "image/png",
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "gif": "image/gif",
            "webp": "image/webp",
            "heic": "image/heic",
            "heif": "image/heif",
            "tif": "image/tiff",
            "tiff": "image/tiff",
            "bmp": "image/bmp",
        ]
        let fileExtension = (filename as NSString).pathExtension.lowercased()
        if let known = knownByExtension[fileExtension] { return known }

        let candidate = declared.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard candidate.range(
            of: #"^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$"#,
            options: .regularExpression
        ) != nil else {
            return "application/octet-stream"
        }
        return candidate
    }

    private static func timestamp(_ secondsSince1970: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date(timeIntervalSince1970: secondsSince1970))
    }

    private static func error(_ code: String, _ message: String) -> ServiceError {
        ServiceError(code: code, message: message)
    }
}
