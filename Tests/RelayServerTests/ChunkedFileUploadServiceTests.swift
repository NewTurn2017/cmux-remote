import CryptoKit
import Darwin
import Foundation
import RelayCore
import Testing
@testable import RelayServer

@Suite(.serialized)
struct ChunkedFileUploadServiceTests {
    private let deviceID = "authenticated-device"

    @Test
    func realMultiChunkZIPCommitHasExactBytesHashPermissionsAndNoTemporaryResidue() async throws {
        let fixture = Data("PK\u{3}\u{4}".utf8) + Data(repeating: 0xA5, count: ChunkedFileUploadService.maxChunkBytes * 2 + 17)
        let context = try TestContext()
        defer { context.remove() }
        let service = context.service()
        let uploadID = UUID().uuidString
        let expectedHash = sha256(fixture)

        let begun = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: "zip-batch",
            filename: "fixture.zip",
            mimeType: "application/zip",
            declaredBytes: Int64(fixture.count),
            sha256: expectedHash
        )
        #expect(begun.offset == 0)
        #expect(begun.result == nil)
        #expect(try permissions(of: context.uploads) == 0o700)
        let temporary = try #require(
            FileManager.default.contentsOfDirectory(at: context.uploads, includingPropertiesForKeys: nil).first
        )
        #expect(try permissions(of: temporary) == 0o600)

        var offset = 0
        while offset < fixture.count {
            let end = min(offset + ChunkedFileUploadService.maxChunkBytes, fixture.count)
            let nextOffset = try await service.chunk(
                authenticatedDeviceID: deviceID,
                uploadID: uploadID,
                offset: Int64(offset),
                dataBase64: fixture[offset..<end].base64EncodedString()
            )
            #expect(nextOffset == Int64(end))
            offset = end
        }

        let result = try await service.commit(authenticatedDeviceID: deviceID, uploadID: uploadID)
        let destination = URL(fileURLWithPath: result.path)
        #expect(result.bytes == Int64(fixture.count))
        #expect(result.sha256 == expectedHash)
        #expect(result.mimeType == "application/zip")
        #expect(try streamedSHA256(destination) == expectedHash)
        #expect(try Data(contentsOf: destination) == fixture)
        #expect(try permissions(of: context.root) == 0o700)
        #expect(try permissions(of: destination) == 0o600)
        #expect(!FileManager.default.fileExists(atPath: context.uploads.path))
    }

    @Test
    func exactHundredMiBBoundaryStreamsSuccessfullyAndPlusOneRejectsBeforeTempCreation() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let service = context.service()
        let chunk = Data(repeating: 0x5A, count: ChunkedFileUploadService.maxChunkBytes)
        var hasher = SHA256()
        for _ in 0..<(ChunkedFileUploadService.maxFileBytes / Int64(chunk.count)) {
            hasher.update(data: chunk)
        }
        let expectedHash = hasher.finalize().hex
        let uploadID = UUID().uuidString

        _ = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: "boundary-batch",
            filename: "boundary.bin",
            mimeType: "application/octet-stream",
            declaredBytes: ChunkedFileUploadService.maxFileBytes,
            sha256: expectedHash
        )
        var offset: Int64 = 0
        while offset < ChunkedFileUploadService.maxFileBytes {
            offset = try await service.chunk(
                authenticatedDeviceID: deviceID,
                uploadID: uploadID,
                offset: offset,
                dataBase64: chunk.base64EncodedString()
            )
        }
        let committed = try await service.commit(authenticatedDeviceID: deviceID, uploadID: uploadID)
        #expect(committed.bytes == ChunkedFileUploadService.maxFileBytes)
        #expect(try fileSize(URL(fileURLWithPath: committed.path)) == ChunkedFileUploadService.maxFileBytes)
        #expect(try streamedSHA256(URL(fileURLWithPath: committed.path)) == expectedHash)
        #expect(!FileManager.default.fileExists(atPath: context.uploads.path))

        await expectError("file_too_large") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID,
                uploadID: UUID().uuidString,
                batchID: "oversized-batch",
                filename: "too-large.bin",
                mimeType: "application/octet-stream",
                declaredBytes: ChunkedFileUploadService.maxFileBytes + 1,
                sha256: self.sha256(Data())
            )
        }
        #expect(!FileManager.default.fileExists(atPath: context.uploads.path))
    }

    @Test
    func chunksRequireCanonicalBase64ExactOffsetAndAtMost512KiB() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let service = context.service()
        let valid = Data(repeating: 7, count: ChunkedFileUploadService.maxChunkBytes)
        let uploadID = UUID().uuidString
        _ = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: "chunk-validation",
            filename: "chunks.bin",
            mimeType: "application/octet-stream",
            declaredBytes: Int64(valid.count),
            sha256: sha256(valid)
        )

        await expectError("invalid_base64") {
            _ = try await service.chunk(
                authenticatedDeviceID: self.deviceID,
                uploadID: uploadID,
                offset: 0,
                dataBase64: valid.base64EncodedString() + "\n"
            )
        }
        await expectError("chunk_too_large") {
            _ = try await service.chunk(
                authenticatedDeviceID: self.deviceID,
                uploadID: uploadID,
                offset: 0,
                dataBase64: (valid + Data([1])).base64EncodedString()
            )
        }
        await expectError("offset_conflict") {
            _ = try await service.chunk(
                authenticatedDeviceID: self.deviceID,
                uploadID: uploadID,
                offset: 1,
                dataBase64: valid.base64EncodedString()
            )
        }

        let offset = try await service.chunk(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            offset: 0,
            dataBase64: valid.base64EncodedString()
        )
        #expect(offset == Int64(valid.count))
        _ = try await service.commit(authenticatedDeviceID: deviceID, uploadID: uploadID)
    }

    @Test
    func shortSizeAndWrongHashCommitFailuresRemoveAllTemporaryAndDestinationState() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let service = context.service()
        let shortID = UUID().uuidString
        _ = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: shortID,
            batchID: "failure-batch",
            filename: "short.zip",
            mimeType: "application/zip",
            declaredBytes: 2,
            sha256: sha256(Data([1, 2]))
        )
        _ = try await service.chunk(
            authenticatedDeviceID: deviceID,
            uploadID: shortID,
            offset: 0,
            dataBase64: Data([1]).base64EncodedString()
        )
        await expectError("size_mismatch") {
            _ = try await service.commit(authenticatedDeviceID: self.deviceID, uploadID: shortID)
        }
        #expect(context.destinationFiles().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: context.uploads.path))

        let hashID = UUID().uuidString
        _ = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: hashID,
            batchID: "failure-batch",
            filename: "wrong-hash.zip",
            mimeType: "application/zip",
            declaredBytes: 1,
            sha256: sha256(Data([9]))
        )
        _ = try await service.chunk(
            authenticatedDeviceID: deviceID,
            uploadID: hashID,
            offset: 0,
            dataBase64: Data([8]).base64EncodedString()
        )
        await expectError("hash_mismatch") {
            _ = try await service.commit(authenticatedDeviceID: self.deviceID, uploadID: hashID)
        }
        #expect(context.destinationFiles().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: context.uploads.path))
    }

    @Test
    func cancelIsIdempotentDeletesTempAndAllowsSameIDToRestart() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let service = context.service()
        let bytes = Data([1, 2, 3])
        let uploadID = UUID().uuidString

        _ = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: "cancel-batch",
            filename: "cancel.bin",
            mimeType: "application/octet-stream",
            declaredBytes: 3,
            sha256: sha256(bytes)
        )
        _ = try await service.chunk(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            offset: 0,
            dataBase64: Data([1]).base64EncodedString()
        )
        let resumed = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: "cancel-batch",
            filename: "cancel.bin",
            mimeType: "application/octet-stream",
            declaredBytes: 3,
            sha256: sha256(bytes)
        )
        #expect(resumed.offset == 1)

        try await service.cancel(authenticatedDeviceID: deviceID, uploadID: uploadID)
        try await service.cancel(authenticatedDeviceID: deviceID, uploadID: uploadID)
        #expect(!FileManager.default.fileExists(atPath: context.uploads.path))
        let restarted = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: "cancel-batch",
            filename: "cancel.bin",
            mimeType: "application/octet-stream",
            declaredBytes: 3,
            sha256: sha256(bytes)
        )
        #expect(restarted.offset == 0)
        try await service.cancel(authenticatedDeviceID: deviceID, uploadID: uploadID)
    }

    @Test
    func fakeClockCleanupExpiresAtOneHourAndStaleOperationsFail() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let service = context.service()
        #expect(context.scheduler.requestedDelays == [0])
        await context.scheduler.runNext()
        let uploadID = UUID().uuidString
        _ = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: "ttl-batch",
            filename: "ttl.bin",
            mimeType: "application/octet-stream",
            declaredBytes: 1,
            sha256: sha256(Data([1]))
        )
        #expect(context.scheduler.pendingCount == 1)
        #expect(context.scheduler.requestedDelays == [0, ChunkedFileUploadService.abandonedUploadTTL])

        context.clock.advance(by: ChunkedFileUploadService.abandonedUploadTTL - 1)
        await context.scheduler.runNext()
        let stillActive = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: "ttl-batch",
            filename: "ttl.bin",
            mimeType: "application/octet-stream",
            declaredBytes: 1,
            sha256: sha256(Data([1]))
        )
        #expect(stillActive.offset == 0)

        context.clock.advance(by: ChunkedFileUploadService.abandonedUploadTTL)
        await context.scheduler.runNext()
        await expectError("upload_not_found") {
            _ = try await service.chunk(
                authenticatedDeviceID: self.deviceID,
                uploadID: uploadID,
                offset: 0,
                dataBase64: Data([1]).base64EncodedString()
            )
        }
        #expect(!FileManager.default.fileExists(atPath: context.uploads.path))
        #expect(context.destinationFiles().isEmpty)
    }

    @Test
    func recreatedActorSchedulesExpiredOrphanCleanupWithoutBegin() async throws {
        let context = try TestContext()
        defer { context.remove() }
        try FileManager.default.createDirectory(at: context.uploads, withIntermediateDirectories: true)
        let orphanName = UUID().uuidString.lowercased() + ".part"
        let orphan = context.uploads.appendingPathComponent(orphanName)
        try Data([0xDE, 0xAD]).write(to: orphan)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: context.clock.now - ChunkedFileUploadService.abandonedUploadTTL)],
            ofItemAtPath: orphan.path
        )

        let recreated = context.service()
        defer { _ = recreated }

        #expect(context.scheduler.requestedDelays == [0])
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        await context.scheduler.runNext()
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: context.uploads.path))
    }

    @Test
    func recreatedActorSchedulesNonexpiredOrphanForRemainingTTLWithoutBegin() async throws {
        let context = try TestContext()
        defer { context.remove() }
        try FileManager.default.createDirectory(at: context.uploads, withIntermediateDirectories: true)
        let orphanName = UUID().uuidString.lowercased() + ".part"
        let orphan = context.uploads.appendingPathComponent(orphanName)
        try Data([0xBE, 0xEF]).write(to: orphan)
        let elapsed: TimeInterval = 600
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: context.clock.now - elapsed)],
            ofItemAtPath: orphan.path
        )

        let recreated = context.service()
        defer { _ = recreated }

        #expect(context.scheduler.requestedDelays == [0])
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        await context.scheduler.runNext()
        #expect(context.scheduler.requestedDelays == [0, ChunkedFileUploadService.abandonedUploadTTL - elapsed])
        context.clock.advance(by: ChunkedFileUploadService.abandonedUploadTTL - elapsed)
        await context.scheduler.runNext()
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: context.uploads.path))
    }

    @Test
    func orphanScanResourceOwnerClosesEveryDescriptorOnDestruction() throws {
        let directoryURL = try physicalTemporaryDirectory()
        let rootDescriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        try #require(rootDescriptor >= 0)
        let uploadsDescriptor = Darwin.dup(rootDescriptor)
        try #require(uploadsDescriptor >= 0)
        let streamDescriptor = Darwin.dup(rootDescriptor)
        try #require(streamDescriptor >= 0)
        let openedDirectory = Darwin.fdopendir(streamDescriptor)
        let directory = try #require(openedDirectory)
        let ownedDescriptors = [rootDescriptor, uploadsDescriptor, Darwin.dirfd(directory)]

        var resources: ChunkedFileUploadService.OrphanScanResources? = .init(
            rootDescriptor: rootDescriptor,
            uploadsDescriptor: uploadsDescriptor,
            directory: directory
        )
        for descriptor in ownedDescriptors {
            #expect(Darwin.fcntl(descriptor, F_GETFD) >= 0)
        }

        resources = nil
        #expect(resources == nil)
        for descriptor in ownedDescriptors {
            errno = 0
            #expect(Darwin.fcntl(descriptor, F_GETFD) == -1)
            #expect(errno == EBADF)
        }
    }

    @Test
    func startupCleanupProcessesMoreThanConcurrentLimitInBoundedSlices() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let orphanCount = ChunkedFileUploadService.maxConcurrentUploads * 2 + 3
        try createExpiredOrphans(count: orphanCount, context: context)

        let service = context.service()
        defer { _ = service }

        #expect(context.scheduler.pendingCount == 1)
        #expect(context.scheduler.requestedDelays == [0])
        #expect(try FileManager.default.contentsOfDirectory(atPath: context.uploads.path).count == orphanCount)

        await context.scheduler.runNext()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: context.uploads.path).count
                == orphanCount - ChunkedFileUploadService.maxConcurrentUploads
        )
        #expect(context.scheduler.pendingCount == 1)
        #expect(context.scheduler.maxPendingCount == 1)

        await context.scheduler.runUntilIdle(maximumActions: orphanCount + 2)
        #expect(context.scheduler.pendingCount == 0)
        #expect(context.scheduler.maxPendingCount == 1)
        #expect(!FileManager.default.fileExists(atPath: context.uploads.path))

        let uploadID = UUID().uuidString
        _ = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: "post-cleanup-liveness",
            filename: "alive.bin",
            mimeType: "application/octet-stream",
            declaredBytes: 0,
            sha256: sha256(Data())
        )
        try await service.cancel(authenticatedDeviceID: deviceID, uploadID: uploadID)
    }

    @Test
    func startupCleanupContinuesAcrossRepeatedActorRestart() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let orphanCount = ChunkedFileUploadService.maxConcurrentUploads * 2 + 1
        try createExpiredOrphans(count: orphanCount, context: context)

        let firstScheduler = ManualCleanupScheduler()
        var firstService: ChunkedFileUploadService? = context.service(scheduler: firstScheduler)
        #expect(firstService != nil)
        await firstScheduler.runNext()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: context.uploads.path).count
                == orphanCount - ChunkedFileUploadService.maxConcurrentUploads
        )
        firstService = nil

        let secondScheduler = ManualCleanupScheduler()
        let secondService = context.service(scheduler: secondScheduler)
        defer { _ = secondService }
        await secondScheduler.runUntilIdle(maximumActions: orphanCount + 2)
        #expect(secondScheduler.maxPendingCount == 1)
        #expect(secondScheduler.pendingCount == 0)
        #expect(!FileManager.default.fileExists(atPath: context.uploads.path))

        let thirdScheduler = ManualCleanupScheduler()
        let thirdService = context.service(scheduler: thirdScheduler)
        defer { _ = thirdService }
        await thirdScheduler.runUntilIdle(maximumActions: 2)
        #expect(thirdScheduler.requestedDelays == [0])
        #expect(thirdScheduler.pendingCount == 0)
    }

    @Test
    func symlinkedIntermediateDownloadsDirectoryIsRejectedWithoutMutation() async throws {
        let parent = try physicalTemporaryDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = parent.appendingPathComponent("home", isDirectory: true)
        let attackerDownloads = parent.appendingPathComponent("attacker-downloads", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let root = downloads.appendingPathComponent("cmux-remote", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: attackerDownloads, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: downloads, withDestinationURL: attackerDownloads)
        defer { try? FileManager.default.removeItem(at: parent) }
        let service = ChunkedFileUploadService(rootURL: root)

        await expectError("symlink_root") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID,
                uploadID: UUID().uuidString,
                batchID: "intermediate-downloads-symlink",
                filename: "blocked.bin",
                mimeType: "application/octet-stream",
                declaredBytes: 0,
                sha256: self.sha256(Data())
            )
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: attackerDownloads.path))?.isEmpty == true)
    }

    @Test
    func stagingSymlinkAliasInstalledAfterOpenIsRejectedBeforeCreate() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let replacement = SymlinkAliasReplacementGate(
            original: context.uploads,
            displaced: context.root.appendingPathComponent(".uploads-displaced", isDirectory: true),
            expected: .beforeTemporaryFileCreate
        )
        let service = context.service(filesystemCheckpoint: { [replacement] checkpoint in
            replacement.call(checkpoint)
        })

        await expectError("symlink_root") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID,
                uploadID: UUID().uuidString,
                batchID: "staging-alias-symlink",
                filename: "blocked.bin",
                mimeType: "application/octet-stream",
                declaredBytes: 0,
                sha256: self.sha256(Data())
            )
        }
        #expect(replacement.fired)
        #expect(replacement.partFiles.isEmpty)
    }

    @Test
    func intermediateDownloadsSymlinkAliasFailsIdentityValidation() async throws {
        let parent = try physicalTemporaryDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = parent.appendingPathComponent("home", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let root = downloads.appendingPathComponent("cmux-remote", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let replacement = SymlinkAliasReplacementGate(
            original: downloads,
            displaced: parent.appendingPathComponent("displaced-downloads", isDirectory: true),
            expected: .beforeTemporaryFileCreate
        )
        let service = ChunkedFileUploadService(
            rootURL: root,
            filesystemCheckpoint: { [replacement] checkpoint in replacement.call(checkpoint) }
        )

        await expectError("symlink_root") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID,
                uploadID: UUID().uuidString,
                batchID: "intermediate-alias-symlink",
                filename: "blocked.bin",
                mimeType: "application/octet-stream",
                declaredBytes: 0,
                sha256: self.sha256(Data())
            )
        }
        #expect(replacement.fired)
        #expect(replacement.partFiles.isEmpty)
    }

    @Test
    func injectedUUIDSourceNamesTheReservedPartFile() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let injectedUUID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let service = context.service(uuidSource: { injectedUUID })
        let uploadID = UUID().uuidString

        _ = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: "uuid-source",
            filename: "uuid.bin",
            mimeType: "application/octet-stream",
            declaredBytes: 0,
            sha256: sha256(Data())
        )

        let names = try FileManager.default.contentsOfDirectory(atPath: context.uploads.path)
        #expect(names == ["11111111-2222-3333-4444-555555555555.part"])
        try await service.cancel(authenticatedDeviceID: deviceID, uploadID: uploadID)
    }

    @Test
    func rootReplacementAfterVerificationCannotRedirectTemporaryCreate() async throws {
        let context = try TestContext()
        defer { context.remove() }
        try FileManager.default.createDirectory(at: context.root, withIntermediateDirectories: true)
        let replacement = RootReplacementGate(
            root: context.root,
            parent: context.parent,
            expected: .beforeTemporaryFileCreate
        )
        let service = context.service(filesystemCheckpoint: { [replacement] checkpoint in
            replacement.call(checkpoint)
        })

        await expectError("symlink_root") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID,
                uploadID: UUID().uuidString,
                batchID: "root-replacement-create",
                filename: "blocked.bin",
                mimeType: "application/octet-stream",
                declaredBytes: 0,
                sha256: self.sha256(Data())
            )
        }

        #expect(replacement.fired)
        #expect(replacement.attackerContents.isEmpty)
        #expect(replacement.displacedContents.isEmpty)
    }

    @Test
    func rootReplacementAfterVerificationCannotRedirectAtomicRename() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let replacement = RootReplacementGate(
            root: context.root,
            parent: context.parent,
            expected: .beforeAtomicRename
        )
        let service = context.service(filesystemCheckpoint: { [replacement] checkpoint in
            replacement.call(checkpoint)
        })
        let bytes = Data([0x50, 0x4B, 0x03, 0x04])
        let uploadID = UUID().uuidString
        _ = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: "root-replacement-rename",
            filename: "blocked.zip",
            mimeType: "application/zip",
            declaredBytes: Int64(bytes.count),
            sha256: sha256(bytes)
        )
        _ = try await service.chunk(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            offset: 0,
            dataBase64: bytes.base64EncodedString()
        )

        await expectError("symlink_root") {
            _ = try await service.commit(authenticatedDeviceID: self.deviceID, uploadID: uploadID)
        }

        #expect(replacement.fired)
        #expect(replacement.attackerContents.isEmpty)
        #expect(replacement.displacedContents.isEmpty)
    }

    @Test
    func symlinkDestinationRootIsRejectedWithoutFollowingIt() async throws {
        let parent = try physicalTemporaryDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
        let actual = parent.appendingPathComponent("actual", isDirectory: true)
        let root = parent.appendingPathComponent("cmux-remote", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: actual)
        defer { try? FileManager.default.removeItem(at: parent) }
        let service = ChunkedFileUploadService(rootURL: root)

        await expectError("symlink_root") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID,
                uploadID: UUID().uuidString,
                batchID: "symlink-batch",
                filename: "blocked.zip",
                mimeType: "application/zip",
                declaredBytes: 0,
                sha256: self.sha256(Data())
            )
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: actual.path))?.isEmpty == true)
    }

    @Test
    func caseInsensitiveExistingNameGetsDuplicateSuffixWithoutOverwrite() async throws {
        let context = try TestContext(now: 1_700_000_000)
        defer { context.remove() }
        try FileManager.default.createDirectory(at: context.root, withIntermediateDirectories: true)
        let existing = context.root.appendingPathComponent("20231114-221320-REPORT.ZIP")
        try Data([0xCC]).write(to: existing)
        let service = context.service()
        let uploadID = UUID().uuidString
        let bytes = Data([0x50, 0x4B])
        _ = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: "collision-batch",
            filename: "report.zip",
            mimeType: "application/zip",
            declaredBytes: 2,
            sha256: sha256(bytes)
        )
        _ = try await service.chunk(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            offset: 0,
            dataBase64: bytes.base64EncodedString()
        )
        let result = try await service.commit(authenticatedDeviceID: deviceID, uploadID: uploadID)

        #expect(result.filename == "20231114-221320-report-2.zip")
        #expect(try Data(contentsOf: existing) == Data([0xCC]))
        #expect(try Data(contentsOf: URL(fileURLWithPath: result.path)) == bytes)
    }

    @Test
    func zeroByteUploadCommitsWithExactSHA() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let service = context.service()
        let uploadID = UUID().uuidString
        let emptyHash = sha256(Data())
        _ = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: "empty-batch",
            filename: "empty.bin",
            mimeType: "application/octet-stream",
            declaredBytes: 0,
            sha256: emptyHash
        )

        let result = try await service.commit(authenticatedDeviceID: deviceID, uploadID: uploadID)
        #expect(result.bytes == 0)
        #expect(result.sha256 == emptyHash)
        #expect(try fileSize(URL(fileURLWithPath: result.path)) == 0)
        #expect(!FileManager.default.fileExists(atPath: context.uploads.path))
    }

    @Test
    func repeatedIDResumesOrReturnsResultAndConflictingMetadataIsRejected() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let service = context.service()
        let uploadID = UUID().uuidString
        let bytes = Data([4, 5])
        let metadata = (
            batchID: "resume-batch",
            filename: "resume.bin",
            mimeType: "application/octet-stream",
            declaredBytes: Int64(bytes.count),
            hash: sha256(bytes)
        )
        _ = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: metadata.batchID,
            filename: metadata.filename,
            mimeType: metadata.mimeType,
            declaredBytes: metadata.declaredBytes,
            sha256: metadata.hash
        )
        _ = try await service.chunk(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            offset: 0,
            dataBase64: bytes.base64EncodedString()
        )
        let resumed = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: metadata.batchID,
            filename: metadata.filename,
            mimeType: metadata.mimeType,
            declaredBytes: metadata.declaredBytes,
            sha256: metadata.hash
        )
        #expect(resumed.offset == 2)

        await expectError("upload_conflict") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID,
                uploadID: uploadID,
                batchID: metadata.batchID,
                filename: "different.bin",
                mimeType: metadata.mimeType,
                declaredBytes: metadata.declaredBytes,
                sha256: metadata.hash
            )
        }
        await expectError("device_scope_mismatch") {
            _ = try await service.begin(
                authenticatedDeviceID: "different-device",
                uploadID: uploadID,
                batchID: metadata.batchID,
                filename: metadata.filename,
                mimeType: metadata.mimeType,
                declaredBytes: metadata.declaredBytes,
                sha256: metadata.hash
            )
        }

        let committed = try await service.commit(authenticatedDeviceID: deviceID, uploadID: uploadID)
        let repeated = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: metadata.batchID,
            filename: metadata.filename,
            mimeType: metadata.mimeType,
            declaredBytes: metadata.declaredBytes,
            sha256: metadata.hash
        )
        #expect(repeated.offset == 2)
        #expect(repeated.result == committed)
        #expect(try await service.commit(authenticatedDeviceID: deviceID, uploadID: uploadID) == committed)
        try await service.cancel(authenticatedDeviceID: deviceID, uploadID: uploadID)
        #expect(FileManager.default.fileExists(atPath: committed.path))
    }

    @Test
    func filenameAndMIMEAreNormalizedAgainAtRelayBoundary() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let service = context.service()
        let uploadID = UUID().uuidString
        _ = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: uploadID,
            batchID: "normalization-batch",
            filename: "../.Re\u{301}sume\u{301}\u{202E}.PDF... ",
            mimeType: "image/jpeg",
            declaredBytes: 0,
            sha256: sha256(Data())
        )
        let result = try await service.commit(authenticatedDeviceID: deviceID, uploadID: uploadID)

        #expect(result.filename.hasSuffix("-Résumé-.PDF"))
        #expect(result.mimeType == "application/pdf")
        #expect(!result.filename.contains("\u{202E}"))

        let unknownID = UUID().uuidString
        _ = try await service.begin(
            authenticatedDeviceID: deviceID,
            uploadID: unknownID,
            batchID: "normalization-batch",
            filename: "unknown-extensionless-file",
            mimeType: "not a mime",
            declaredBytes: 0,
            sha256: sha256(Data())
        )
        let unknown = try await service.commit(authenticatedDeviceID: deviceID, uploadID: unknownID)
        #expect(unknown.filename.hasSuffix("-attachment.bin"))
        #expect(unknown.mimeType == "application/octet-stream")
    }

    @Test
    func perBatchAndConcurrencyLimitsRejectBeforeCreatingAdditionalTemps() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let service = context.service()
        let emptyHash = sha256(Data())
        var uploadIDs: [String] = []

        for index in 0..<ChunkedFileUploadService.maxConcurrentUploads {
            let uploadID = UUID().uuidString
            uploadIDs.append(uploadID)
            _ = try await service.begin(
                authenticatedDeviceID: deviceID,
                uploadID: uploadID,
                batchID: "batch-\(index)",
                filename: "\(index).bin",
                mimeType: "application/octet-stream",
                declaredBytes: 0,
                sha256: emptyHash
            )
        }
        let tempCount = (try? FileManager.default.contentsOfDirectory(atPath: context.uploads.path).count)
        await expectError("too_many_uploads") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID,
                uploadID: UUID().uuidString,
                batchID: "concurrency-overflow",
                filename: "overflow.bin",
                mimeType: "application/octet-stream",
                declaredBytes: 0,
                sha256: emptyHash
            )
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: context.uploads.path).count) == tempCount)
        for uploadID in uploadIDs {
            try await service.cancel(authenticatedDeviceID: deviceID, uploadID: uploadID)
        }

        let batchID = "size-limited-batch"
        let sizes: [Int64] = [ChunkedFileUploadService.maxFileBytes, ChunkedFileUploadService.maxFileBytes, 50 * 1024 * 1024]
        uploadIDs.removeAll()
        for (index, size) in sizes.enumerated() {
            let uploadID = UUID().uuidString
            uploadIDs.append(uploadID)
            _ = try await service.begin(
                authenticatedDeviceID: deviceID,
                uploadID: uploadID,
                batchID: batchID,
                filename: "large-\(index).bin",
                mimeType: "application/octet-stream",
                declaredBytes: size,
                sha256: emptyHash
            )
        }
        await expectError("batch_too_large") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID,
                uploadID: UUID().uuidString,
                batchID: batchID,
                filename: "one-byte-too-many.bin",
                mimeType: "application/octet-stream",
                declaredBytes: 1,
                sha256: emptyHash
            )
        }
        for uploadID in uploadIDs {
            try await service.cancel(authenticatedDeviceID: deviceID, uploadID: uploadID)
        }

        let fileCountBatchID = "file-count-limited-batch"
        for index in 0..<ChunkedFileUploadService.maxBatchFiles {
            let uploadID = UUID().uuidString
            _ = try await service.begin(
                authenticatedDeviceID: deviceID,
                uploadID: uploadID,
                batchID: fileCountBatchID,
                filename: "empty-\(index).bin",
                mimeType: "application/octet-stream",
                declaredBytes: 0,
                sha256: emptyHash
            )
            _ = try await service.commit(authenticatedDeviceID: deviceID, uploadID: uploadID)
        }
        await expectError("batch_file_limit") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID,
                uploadID: UUID().uuidString,
                batchID: fileCountBatchID,
                filename: "eleventh.bin",
                mimeType: "application/octet-stream",
                declaredBytes: 0,
                sha256: emptyHash
            )
        }
        #expect(!FileManager.default.fileExists(atPath: context.uploads.path))
    }

    @Test
    func stableBatchDeclarationEnforcesLimitsAcrossIndependentBeginsAndDevices() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let service = context.service()
        let batchID = UUID().uuidString
        let emptyHash = sha256(Data())

        for index in 0..<ChunkedFileUploadService.maxBatchFiles {
            let uploadID = UUID().uuidString
            _ = try await service.begin(
                authenticatedDeviceID: deviceID,
                uploadID: uploadID,
                batchID: batchID,
                batchFileCount: ChunkedFileUploadService.maxBatchFiles,
                batchBytes: 0,
                filename: "reconnect-\(index).bin",
                mimeType: "application/octet-stream",
                declaredBytes: 0,
                sha256: emptyHash
            )
            _ = try await service.commit(authenticatedDeviceID: deviceID, uploadID: uploadID)
        }
        await expectError("batch_file_limit") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID,
                uploadID: UUID().uuidString,
                batchID: batchID,
                batchFileCount: ChunkedFileUploadService.maxBatchFiles,
                batchBytes: 0,
                filename: "eleventh.bin",
                mimeType: "application/octet-stream",
                declaredBytes: 0,
                sha256: emptyHash
            )
        }
        await expectError("batch_conflict") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID,
                uploadID: UUID().uuidString,
                batchID: batchID,
                batchFileCount: ChunkedFileUploadService.maxBatchFiles - 1,
                batchBytes: 0,
                filename: "conflicting-total.bin",
                mimeType: "application/octet-stream",
                declaredBytes: 0,
                sha256: emptyHash
            )
        }

        let otherDeviceUploadID = UUID().uuidString
        _ = try await service.begin(
            authenticatedDeviceID: "other-device",
            uploadID: otherDeviceUploadID,
            batchID: batchID,
            batchFileCount: 1,
            batchBytes: 0,
            filename: "other-device.bin",
            mimeType: "application/octet-stream",
            declaredBytes: 0,
            sha256: emptyHash
        )
        _ = try await service.commit(
            authenticatedDeviceID: "other-device",
            uploadID: otherDeviceUploadID
        )
    }

    @Test
    func stableBatchDeclarationRetainsAggregateBytesAcrossIndependentBegins() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let service = context.service()
        let batchID = UUID().uuidString
        let emptyHash = sha256(Data())
        let sizes: [Int64] = [
            ChunkedFileUploadService.maxFileBytes,
            ChunkedFileUploadService.maxFileBytes,
            50 * 1024 * 1024,
        ]
        var uploadIDs: [String] = []

        for (index, size) in sizes.enumerated() {
            let uploadID = UUID().uuidString
            uploadIDs.append(uploadID)
            _ = try await service.begin(
                authenticatedDeviceID: deviceID,
                uploadID: uploadID,
                batchID: batchID,
                batchFileCount: 4,
                batchBytes: ChunkedFileUploadService.maxBatchBytes,
                filename: "aggregate-\(index).bin",
                mimeType: "application/octet-stream",
                declaredBytes: size,
                sha256: emptyHash
            )
        }
        await expectError("batch_too_large") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID,
                uploadID: UUID().uuidString,
                batchID: batchID,
                batchFileCount: 4,
                batchBytes: ChunkedFileUploadService.maxBatchBytes,
                filename: "overflow.bin",
                mimeType: "application/octet-stream",
                declaredBytes: 1,
                sha256: emptyHash
            )
        }
        for uploadID in uploadIDs {
            try await service.cancel(authenticatedDeviceID: deviceID, uploadID: uploadID)
        }
    }

    @Test
    func uniqueCancelledBatchChurnRetainsNoStandaloneBookkeeping() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let service = context.service()
        await context.scheduler.runNext()
        let emptyHash = sha256(Data())

        for index in 0..<128 {
            let uploadID = UUID().uuidString
            _ = try await service.begin(
                authenticatedDeviceID: deviceID,
                uploadID: uploadID,
                batchID: "cancel-churn-\(index)",
                batchFileCount: 1,
                batchBytes: 0,
                filename: "cancel-\(index).bin",
                mimeType: "application/octet-stream",
                declaredBytes: 0,
                sha256: emptyHash
            )
            try await service.cancel(authenticatedDeviceID: deviceID, uploadID: uploadID)
        }

        #expect(await service.retainedBatchUsageCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: context.uploads.path))
        #expect(context.destinationFiles().isEmpty)
    }

    @Test
    func completedBatchMetadataStillEnforcesAggregateAndDeclarationAfterBookkeepingEviction() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let service = context.service()
        let batchID = "completed-aggregate"
        let oneByte = Data([0x41])
        let oneByteHash = sha256(oneByte)

        for index in 0..<2 {
            let uploadID = UUID().uuidString
            _ = try await service.begin(
                authenticatedDeviceID: deviceID,
                uploadID: uploadID,
                batchID: batchID,
                batchFileCount: 3,
                batchBytes: 2,
                filename: "completed-\(index).bin",
                mimeType: "application/octet-stream",
                declaredBytes: 1,
                sha256: oneByteHash
            )
            _ = try await service.chunk(
                authenticatedDeviceID: deviceID,
                uploadID: uploadID,
                offset: 0,
                dataBase64: oneByte.base64EncodedString()
            )
            _ = try await service.commit(authenticatedDeviceID: deviceID, uploadID: uploadID)
        }

        #expect(await service.retainedBatchUsageCount() == 0)
        await expectError("batch_too_large") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID,
                uploadID: UUID().uuidString,
                batchID: batchID,
                batchFileCount: 3,
                batchBytes: 2,
                filename: "overflow.bin",
                mimeType: "application/octet-stream",
                declaredBytes: 1,
                sha256: oneByteHash
            )
        }
        await expectError("batch_conflict") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID,
                uploadID: UUID().uuidString,
                batchID: batchID,
                batchFileCount: 2,
                batchBytes: 2,
                filename: "conflict.bin",
                mimeType: "application/octet-stream",
                declaredBytes: 0,
                sha256: self.sha256(Data())
            )
        }

        let otherDeviceID = UUID().uuidString
        _ = try await service.begin(
            authenticatedDeviceID: "other-device",
            uploadID: otherDeviceID,
            batchID: batchID,
            batchFileCount: 1,
            batchBytes: 0,
            filename: "other-device.bin",
            mimeType: "application/octet-stream",
            declaredBytes: 0,
            sha256: sha256(Data())
        )
        _ = try await service.commit(authenticatedDeviceID: "other-device", uploadID: otherDeviceID)
    }

    @Test
    func malformedBeginInputFailsBeforeFilesystemMutation() async throws {
        let context = try TestContext()
        defer { context.remove() }
        let service = context.service()

        await expectError("unauthenticated") {
            _ = try await service.begin(
                authenticatedDeviceID: " ", uploadID: UUID().uuidString, batchID: "bad",
                filename: "x.bin", mimeType: "application/octet-stream", declaredBytes: 0,
                sha256: self.sha256(Data())
            )
        }
        await expectError("invalid_upload_id") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID, uploadID: "not-a-uuid", batchID: "bad",
                filename: "x.bin", mimeType: "application/octet-stream", declaredBytes: 0,
                sha256: self.sha256(Data())
            )
        }
        await expectError("invalid_batch_id") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID, uploadID: UUID().uuidString, batchID: " bad ",
                filename: "x.bin", mimeType: "application/octet-stream", declaredBytes: 0,
                sha256: self.sha256(Data())
            )
        }
        await expectError("invalid_batch_file_count") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID, uploadID: UUID().uuidString, batchID: "bad-count",
                batchFileCount: 0, batchBytes: 0,
                filename: "x.bin", mimeType: "application/octet-stream", declaredBytes: 0,
                sha256: self.sha256(Data())
            )
        }
        await expectError("invalid_batch_bytes") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID, uploadID: UUID().uuidString, batchID: "bad-bytes",
                batchFileCount: 1, batchBytes: ChunkedFileUploadService.maxBatchBytes + 1,
                filename: "x.bin", mimeType: "application/octet-stream", declaredBytes: 0,
                sha256: self.sha256(Data())
            )
        }
        await expectError("invalid_size") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID, uploadID: UUID().uuidString, batchID: "bad",
                filename: "x.bin", mimeType: "application/octet-stream", declaredBytes: -1,
                sha256: self.sha256(Data())
            )
        }
        await expectError("invalid_hash") {
            _ = try await service.begin(
                authenticatedDeviceID: self.deviceID, uploadID: UUID().uuidString, batchID: "bad",
                filename: "x.bin", mimeType: "application/octet-stream", declaredBytes: 0,
                sha256: "not-sha256"
            )
        }
        #expect(!FileManager.default.fileExists(atPath: context.root.path))
    }

    private func createExpiredOrphans(count: Int, context: TestContext) throws {
        try FileManager.default.createDirectory(at: context.uploads, withIntermediateDirectories: true)
        for _ in 0..<count {
            let orphan = context.uploads.appendingPathComponent(UUID().uuidString.lowercased() + ".part")
            try Data([0xDE, 0xAD]).write(to: orphan)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(
                    timeIntervalSince1970: context.clock.now - ChunkedFileUploadService.abandonedUploadTTL
                )],
                ofItemAtPath: orphan.path
            )
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).hex
    }

    private func expectError(
        _ code: String,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected ChunkedFileUploadService error \(code)")
        } catch let error as ChunkedFileUploadService.ServiceError {
            #expect(error.code == code)
        } catch {
            Issue.record("Expected ChunkedFileUploadService error \(code), got \(error)")
        }
    }

    private func streamedSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 512 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().hex
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.size] as? NSNumber)?.int64Value)
    }
}

// The serialized suite accesses this fake only across awaited service-call boundaries.
private final class ManualCleanupScheduler: @unchecked Sendable {
    private var entries: [(delay: TimeInterval, action: @Sendable () async -> Void)] = []
    private var delayHistory: [TimeInterval] = []
    private(set) var maxPendingCount = 0

    // Access is sequenced by awaited service calls in this serialized suite.
    var pendingCount: Int { entries.count }
    var requestedDelays: [TimeInterval] { delayHistory }

    func schedule(
        after delay: TimeInterval,
        action: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        entries.append((delay, action))
        delayHistory.append(delay)
        maxPendingCount = max(maxPendingCount, entries.count)
        return Task {}
    }

    func runNext() async {
        guard !entries.isEmpty else {
            Issue.record("Expected a scheduled cleanup action")
            return
        }
        let entry = entries.removeFirst()
        await entry.action()
    }

    func runUntilIdle(maximumActions: Int) async {
        for _ in 0..<maximumActions {
            guard !entries.isEmpty else { return }
            await runNext()
        }
        if !entries.isEmpty {
            Issue.record("Cleanup did not complete within \(maximumActions) scheduled actions")
        }
    }
}

// Immutable URLs plus suite-serialized fake dependencies make this fixture safe to pass to sendable closures.
private final class TestContext: @unchecked Sendable {
    let parent: URL
    let root: URL
    let uploads: URL
    let clock: FakeClock
    let scheduler = ManualCleanupScheduler()

    init(now: TimeInterval = 1_700_000_000) throws {
        parent = try physicalTemporaryDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = parent.appendingPathComponent("cmux-remote", isDirectory: true)
        uploads = root.appendingPathComponent(".uploads", isDirectory: true)
        clock = FakeClock()
        clock.advance(by: now)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    func service(
        scheduler: ManualCleanupScheduler? = nil,
        uuidSource: @escaping @Sendable () -> UUID = { UUID() },
        filesystemCheckpoint: @escaping @Sendable (ChunkedFileUploadService.FilesystemCheckpoint) -> Void = { _ in }
    ) -> ChunkedFileUploadService {
        let selectedScheduler = scheduler ?? self.scheduler
        return ChunkedFileUploadService(
            rootURL: root,
            clock: clock,
            uuidSource: uuidSource,
            cleanupScheduler: { [selectedScheduler] delay, action in
                selectedScheduler.schedule(after: delay, action: action)
            },
            filesystemCheckpoint: filesystemCheckpoint
        )
    }

    func destinationFiles() -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return urls.filter { $0.lastPathComponent != ".uploads" }
    }

    func remove() {
        try? FileManager.default.removeItem(at: parent)
    }
}

// This gate is invoked synchronously by the serialized service actor and inspected after awaited calls.
private final class RootReplacementGate: @unchecked Sendable {
    let displacedRoot: URL
    let attackerRoot: URL
    private let root: URL
    private let expected: ChunkedFileUploadService.FilesystemCheckpoint
    private(set) var fired = false

    init(
        root: URL,
        parent: URL,
        expected: ChunkedFileUploadService.FilesystemCheckpoint
    ) {
        self.root = root
        displacedRoot = parent.appendingPathComponent("displaced-root", isDirectory: true)
        attackerRoot = parent.appendingPathComponent("attacker-root", isDirectory: true)
        self.expected = expected
    }

    func call(_ checkpoint: ChunkedFileUploadService.FilesystemCheckpoint) {
        guard checkpoint == expected, !fired else { return }
        do {
            try FileManager.default.createDirectory(at: attackerRoot, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: root, to: displacedRoot)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: attackerRoot)
            fired = true
        } catch {
            Issue.record("Root replacement gate failed: \(error)")
        }
    }

    var attackerContents: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: attackerRoot.path)) ?? []
    }

    var displacedContents: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: displacedRoot.path)) ?? []
    }
}

// This gate replaces a verified path component with a symlink alias to the same directory.
private final class SymlinkAliasReplacementGate: @unchecked Sendable {
    private let original: URL
    private let displaced: URL
    private let expected: ChunkedFileUploadService.FilesystemCheckpoint
    private(set) var fired = false

    init(
        original: URL,
        displaced: URL,
        expected: ChunkedFileUploadService.FilesystemCheckpoint
    ) {
        self.original = original
        self.displaced = displaced
        self.expected = expected
    }

    func call(_ checkpoint: ChunkedFileUploadService.FilesystemCheckpoint) {
        guard checkpoint == expected, !fired else { return }
        do {
            try FileManager.default.moveItem(at: original, to: displaced)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: displaced)
            fired = true
        } catch {
            Issue.record("Symlink alias replacement gate failed: \(error)")
        }
    }

    var partFiles: [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: displaced,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "part" }
    }
}

private func physicalTemporaryDirectory() throws -> URL {
    let path = FileManager.default.temporaryDirectory.path
    guard let resolved = path.withCString({ Darwin.realpath($0, nil) }) else {
        throw CocoaError(.fileReadUnknown)
    }
    defer { Darwin.free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

private extension Sequence where Element == UInt8 {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
