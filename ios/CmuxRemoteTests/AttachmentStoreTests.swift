import Foundation
import SharedKit
import Testing
@testable import CmuxRemote

@Suite("AttachmentStoreTests")
@MainActor
struct AttachmentStoreTests {
    @Test
    func stagingCompletionTwoZeroOneUploadsInPickerOrder() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let staging = StagingCompletionGate(prepared: try (0..<3).map { try files.prepared(ordinal: $0, byteCount: 1) })
        let rpc = UploadRPCFixture()
        let batchID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let store = AttachmentStore(
            rpc: rpc,
            prepare: { selection, ordinal in
                try await staging.prepare(selection: selection, ordinal: ordinal)
            },
            batchIDSource: { batchID }
        )
        var starts = await staging.starts().makeAsyncIterator()

        await store.startUpload(files.selections(count: 3), hostGeneration: 1)
        var started = Set<Int>()
        while started.count < 3 {
            started.insert(try #require(await starts.next()))
        }
        await staging.release(ordinal: 2)
        await staging.release(ordinal: 0)
        await staging.release(ordinal: 1)
        await store.waitForCurrentOperation()

        #expect(await rpc.beginOrder == ["file-0.bin", "file-1.bin", "file-2.bin"])
        #expect(await rpc.beginRequests.map(\.batchId) == Array(repeating: batchID.uuidString, count: 3))
        #expect(store.items.map(\.ordinal) == [0, 1, 2])
        #expect(store.quotedPaths == [
            "'/Users/test/Downloads/file-0.bin'",
            "'/Users/test/Downloads/file-1.bin'",
            "'/Users/test/Downloads/file-2.bin'",
        ])
    }

    @Test(.timeLimit(.minutes(1)), arguments: StagingInvalidator.allCases)
    func completedConcurrentPreparationIsCleanedWhenOperationBecomesStale(
        invalidator: StagingInvalidator
    ) async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let staged = try (0..<4).map { try files.prepared(ordinal: $0, byteCount: 1) }
        let staging = StagingCompletionGate(prepared: staged)
        let fileManager = RemovalRecordingFileManager()
        let rpc = UploadRPCFixture()
        let store = AttachmentStore(
            rpc: rpc,
            prepare: { selection, ordinal in
                try await staging.prepare(selection: selection, ordinal: ordinal)
            },
            fileManager: fileManager
        )
        var starts = await staging.starts().makeAsyncIterator()
        var removals = fileManager.removals().makeAsyncIterator()

        await store.startUpload(files.selections(count: 4), hostGeneration: 1)
        var started = Set<Int>()
        while started.count < 3 {
            started.insert(try #require(await starts.next()))
        }
        await staging.release(ordinal: 0)
        #expect(await starts.next() == 3)

        switch invalidator {
        case .cancel:
            await store.cancel()
            #expect(store.items.allSatisfy { $0.state == .unattempted })
        case .hostGeneration:
            await store.setHostGeneration(2)
            #expect(store.items.isEmpty)
        }

        let completedWasRemoved = !FileManager.default.fileExists(atPath: staged[0].stagedURL.path)
        #expect(completedWasRemoved)
        #expect(await rpc.beginOrder.isEmpty)
        #expect(await rpc.methods.filter { $0 == RemoteRPCMethod.uploadChunk.rawValue }.isEmpty)
        #expect(await rpc.methods.filter { $0 == RemoteRPCMethod.uploadCommit.rawValue }.isEmpty)

        await staging.releaseAll()
        guard completedWasRemoved else { return }

        var removedURLs = Set<URL>()
        while removedURLs.count < staged.count {
            removedURLs.insert(try #require(await removals.next()))
        }
        #expect(removedURLs == Set(staged.map(\.stagedURL)))
        #expect(staged.allSatisfy { !FileManager.default.fileExists(atPath: $0.stagedURL.path) })
    }

    @Test
    func exactHundredMiBUsesBoundedChunks() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let prepared = try files.prepared(ordinal: 0, byteCount: Int64(ChunkUploadLimits.maxFileBytes), sparse: true)
        let rpc = UploadRPCFixture()
        let store = AttachmentStore(rpc: rpc, prepare: { _, _ in prepared })

        await store.startUpload(files.selections(count: 1), hostGeneration: 1)
        await store.waitForCurrentOperation()

        let chunkSizes = await rpc.chunkSizes
        #expect(chunkSizes.count == 200)
        #expect(chunkSizes.allSatisfy { $0 == ChunkUploadLimits.rawChunkBytes })
        #expect(chunkSizes.reduce(0, +) == ChunkUploadLimits.maxFileBytes)
        #expect(store.progress.sentBytes == Int64(ChunkUploadLimits.maxFileBytes))
        #expect(store.progress.completedFiles == 1)
    }

    @Test
    func fileCountLimitIsEnforcedBeforeStaging() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let rpc = UploadRPCFixture()
        let batchID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000010"))
        let store = AttachmentStore(
            rpc: rpc,
            prepare: { _, ordinal in
                try files.prepared(ordinal: ordinal, byteCount: 1)
            },
            batchIDSource: { batchID }
        )

        await store.startUpload(files.selections(count: 11), hostGeneration: 1)
        await store.waitForCurrentOperation()

        #expect(await rpc.beginOrder.count == ChunkUploadLimits.maxBatchFiles)
        #expect(await rpc.beginRequests.allSatisfy {
            $0.batchId == batchID.uuidString
                && $0.batchFileCount == ChunkUploadLimits.maxBatchFiles
                && $0.batchBytes == ChunkUploadLimits.maxBatchFiles
        })
        #expect(store.items[10].failure?.code == "file_count_limit")
    }

    @Suite
    @MainActor
    struct testExactBatchByteBoundaryIsEnforcedBeforeUpload {
        @Test
        func behavior() async throws {
            let files = try AttachmentStoreFixture()
            defer { files.remove() }
            let exactSizes = [
                Int64(ChunkUploadLimits.maxFileBytes),
                Int64(ChunkUploadLimits.maxFileBytes),
                Int64(50 * 1024 * 1024),
            ]
            let exactPrepared = try exactSizes.enumerated().map {
                try files.prepared(ordinal: $0.offset, byteCount: $0.element, sparse: true)
            }
            let exactRPC = UploadRPCFixture()
            let store = AttachmentStore(
                rpc: exactRPC,
                prepare: { _, ordinal in exactPrepared[ordinal] }
            )

            await store.startUpload(files.selections(count: 3), hostGeneration: 1)
            await store.waitForCurrentOperation()

            #expect(exactSizes.reduce(0, +) == Int64(ChunkUploadLimits.maxBatchBytes))
            #expect(await exactRPC.beginRequests.count == 3)
            #expect(await exactRPC.beginRequests.allSatisfy {
                $0.batchFileCount == 3 && $0.batchBytes == ChunkUploadLimits.maxBatchBytes
            })
            #expect(await exactRPC.methods.filter { $0 == RemoteRPCMethod.uploadChunk.rawValue }.count == 500)
            #expect(await exactRPC.methods.filter { $0 == RemoteRPCMethod.uploadCommit.rawValue }.count == 3)
            #expect(store.items.allSatisfy { $0.isSucceeded })

            let overSizes = [
                Int64(ChunkUploadLimits.maxFileBytes),
                Int64(ChunkUploadLimits.maxFileBytes),
                Int64(50 * 1024 * 1024 + 1),
            ]
            let overPrepared = try overSizes.enumerated().map {
                try files.prepared(ordinal: $0.offset + 3, byteCount: $0.element, sparse: true)
            }
            let overRPC = UploadRPCFixture(rejectAllBegins: true)
            let overStore = AttachmentStore(
                rpc: overRPC,
                prepare: { _, ordinal in overPrepared[ordinal] }
            )

            await overStore.startUpload(files.selections(count: 3), hostGeneration: 2)
            await overStore.waitForCurrentOperation()

            #expect(overSizes.reduce(0, +) == Int64(ChunkUploadLimits.maxBatchBytes + 1))
            #expect(await overRPC.beginRequests.isEmpty)
            #expect(await overRPC.methods.filter { $0 == RemoteRPCMethod.uploadBegin.rawValue }.isEmpty)
            #expect(await overRPC.methods.filter { $0 == RemoteRPCMethod.uploadChunk.rawValue }.isEmpty)
            #expect(await overRPC.methods.filter { $0 == RemoteRPCMethod.uploadCommit.rawValue }.isEmpty)
            #expect(overStore.items.allSatisfy { $0.failure?.code == "batch_size_limit" })
            #expect(overStore.quotedPaths.isEmpty)
            #expect(overPrepared.allSatisfy { !FileManager.default.fileExists(atPath: $0.stagedURL.path) })
        }
    }

    @Suite
    @MainActor
    struct testNewLogicalBatchesUseDistinctIDsWhileRetryRetainsOriginal {
        @Test
        func behavior() async throws {
            let files = try AttachmentStoreFixture()
            defer { files.remove() }
            let firstID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000101"))
            let secondID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000202"))
            let batchIDs = BatchIDSequence([firstID, secondID])
            let rpc = UploadRPCFixture(failChunkOnceFor: ["file-0.bin"])
            let store = AttachmentStore(
                rpc: rpc,
                prepare: { _, ordinal in
                    try files.prepared(ordinal: ordinal, byteCount: 1)
                },
                batchIDSource: { batchIDs.next() }
            )

            await store.startUpload(files.selections(count: 1), hostGeneration: 1)
            await store.waitForCurrentOperation()
            #expect(store.items[0].failure?.retryable == true)

            await store.retryFailed()
            await store.waitForCurrentOperation()
            #expect(store.items[0].isSucceeded)

            await store.startUpload(files.selections(count: 1), hostGeneration: 1)
            await store.waitForCurrentOperation()

            #expect(await rpc.beginRequests.map(\.batchId) == [
                firstID.uuidString,
                firstID.uuidString,
                secondID.uuidString,
            ])
            #expect(batchIDs.consumedCount == 2)
            #expect(store.items[0].isSucceeded)
        }
    }

    @Suite
    @MainActor
    struct testMismatchedBeginBatchIDRetainsRetryStateWithoutPayload {
        @Test
        func behavior() async throws {
            let files = try AttachmentStoreFixture()
            defer { files.remove() }
            let staged = try files.prepared(ordinal: 0, byteCount: 1)
            let requestedID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000303"))
            let mismatchedID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000404"))
            let rpc = UploadRPCFixture(mismatchedBeginBatchIDOnce: mismatchedID.uuidString)
            let store = AttachmentStore(
                rpc: rpc,
                prepare: { _, _ in staged },
                batchIDSource: { requestedID }
            )

            await store.startUpload(files.selections(count: 1), hostGeneration: 1)
            await store.waitForCurrentOperation()

            #expect(store.items[0].failure?.code == "invalid_server_result")
            #expect(store.items[0].failure?.retryable == true)
            #expect(await rpc.beginRequests.map(\.batchId) == [requestedID.uuidString])
            #expect(await rpc.methods.filter { $0 == RemoteRPCMethod.uploadChunk.rawValue }.isEmpty)
            #expect(await rpc.methods.filter { $0 == RemoteRPCMethod.uploadCommit.rawValue }.isEmpty)
            #expect(await rpc.cancelledUploadIDs.isEmpty)
            #expect(store.quotedPaths.isEmpty)
            #expect(FileManager.default.fileExists(atPath: staged.stagedURL.path))

            await store.retryFailed()
            await store.waitForCurrentOperation()

            #expect(await rpc.beginRequests.map(\.batchId) == [requestedID.uuidString, requestedID.uuidString])
            #expect(await rpc.methods.filter { $0 == RemoteRPCMethod.uploadChunk.rawValue }.count == 1)
            #expect(await rpc.methods.filter { $0 == RemoteRPCMethod.uploadCommit.rawValue }.count == 1)
            #expect(store.items[0].isSucceeded)
            #expect(store.quotedPaths == ["'/Users/test/Downloads/file-0.bin'"])
            #expect(!FileManager.default.fileExists(atPath: staged.stagedURL.path))
        }
    }

    @Test
    func progressAdvancesByExactAcknowledgedBytes() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let byteCount = Int64(ChunkUploadLimits.rawChunkBytes + 3)
        let prepared = try files.prepared(ordinal: 0, byteCount: byteCount)
        let chunkGate = CancellableCallGate()
        let rpc = UploadRPCFixture(blockChunkOffset: ChunkUploadLimits.rawChunkBytes, chunkGate: chunkGate)
        let store = AttachmentStore(rpc: rpc, prepare: { _, _ in prepared })
        var blockedCalls = await chunkGate.starts().makeAsyncIterator()

        await store.startUpload(files.selections(count: 1), hostGeneration: 1)
        _ = await blockedCalls.next()
        #expect(store.progress.sentBytes == Int64(ChunkUploadLimits.rawChunkBytes))
        #expect(store.progress.completedFiles == 0)
        await chunkGate.release()
        await store.waitForCurrentOperation()
        #expect(store.progress.sentBytes == byteCount)
        #expect(store.progress.completedFiles == 1)
    }

    @Test
    func acknowledgedBytesSurviveLaterChunkFailure() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let chunkBytes = ChunkUploadLimits.rawChunkBytes
        let prepared = try files.prepared(
            ordinal: 0,
            byteCount: Int64(2 * chunkBytes + 3)
        )
        let rpc = UploadRPCFixture(
            failChunkAtOffset: ["file-0.bin": 2 * chunkBytes]
        )
        let store = AttachmentStore(rpc: rpc, prepare: { _, _ in prepared })

        await store.startUpload(files.selections(count: 1), hostGeneration: 1)
        await store.waitForCurrentOperation()

        #expect(store.items[0].failure?.retryable == true)
        #expect(store.acknowledgedBytes(for: 0) == Int64(2 * chunkBytes))
        #expect(store.totalAcknowledgedBytes == Int64(2 * chunkBytes))
        #expect(store.progress.sentBytes == Int64(2 * chunkBytes))
    }

    @Test
    func cancelSettlesLocallyAndCleansStagingWithFastRelayResponse() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let staged = try [
            files.prepared(
                ordinal: 0,
                byteCount: Int64(ChunkUploadLimits.rawChunkBytes + 1)
            ),
            files.prepared(ordinal: 1, byteCount: 1),
        ]
        let chunkGate = CancellableCallGate()
        let rpc = UploadRPCFixture(
            blockFilename: "file-0.bin",
            blockChunkOffset: ChunkUploadLimits.rawChunkBytes,
            chunkGate: chunkGate
        )
        let store = AttachmentStore(rpc: rpc, prepare: { _, ordinal in staged[ordinal] })
        var blockedChunks = await chunkGate.starts().makeAsyncIterator()

        await store.startUpload(files.selections(count: 2), hostGeneration: 1)
        _ = await blockedChunks.next()
        await store.cancel()

        #expect(!store.isUploading)
        #expect(store.items[0].state == .cancelled)
        #expect(store.items[1].state == .unattempted)
        #expect(store.acknowledgedBytes(for: 0) == Int64(ChunkUploadLimits.rawChunkBytes))
        #expect(store.totalAcknowledgedBytes == Int64(ChunkUploadLimits.rawChunkBytes))
        #expect(store.progress.sentBytes == Int64(ChunkUploadLimits.rawChunkBytes))
        #expect(store.quotedPaths.isEmpty)
        #expect(await rpc.beginOrder == ["file-0.bin"])
        #expect(await rpc.chunkOffsets["file-0.bin"] == [0, ChunkUploadLimits.rawChunkBytes])
        #expect(await rpc.methods.filter { $0 == RemoteRPCMethod.uploadCommit.rawValue }.isEmpty)
        #expect(await rpc.cancelledUploadIDs == ["upload-file-0.bin"])
        #expect(staged.allSatisfy { !FileManager.default.fileExists(atPath: $0.stagedURL.path) })
    }

    @Test
    func relayCancelDeadlineCancelsAndDrainsCooperativeDispatch() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let staged = try files.prepared(
            ordinal: 0,
            byteCount: Int64(ChunkUploadLimits.rawChunkBytes + 1)
        )
        let chunkGate = CancellableCallGate()
        let relayCancel = CancellationCooperativeProbe()
        let deadline = VirtualCancellationDeadline()
        let rpc = UploadRPCFixture(
            blockFilename: staged.filename,
            blockChunkOffset: ChunkUploadLimits.rawChunkBytes,
            chunkGate: chunkGate,
            relayCancel: relayCancel
        )
        let uploader = AttachmentUploader(
            rpc: rpc,
            cancellationDeadline: { try await deadline.sleep() }
        )
        var blockedChunks = await chunkGate.starts().makeAsyncIterator()
        var relayStarts = await relayCancel.starts().makeAsyncIterator()
        var relayDrains = await relayCancel.drains().makeAsyncIterator()
        var deadlineStarts = await deadline.starts().makeAsyncIterator()
        var deadlineDrains = await deadline.drains().makeAsyncIterator()
        let uploadTask = Task {
            try await uploader.upload(
                staged,
                batchID: UUID().uuidString,
                batchFileCount: 1,
                batchBytes: Int(staged.bytes)
            ) { _ in }
        }

        _ = await blockedChunks.next()
        let cancelTask = Task { await uploader.cancelCurrentUpload() }
        _ = await relayStarts.next()
        _ = await deadlineStarts.next()
        await deadline.advance()
        _ = await relayDrains.next()
        _ = await deadlineDrains.next()
        await cancelTask.value

        #expect(await relayCancel.startCount == 1)
        #expect(await relayCancel.drainCount == 1)
        #expect(await relayCancel.activeCount == 0)
        #expect(await deadline.pendingCount == 0)
        #expect(await rpc.cancelledUploadIDs == ["upload-file-0.bin"])
        #expect(await rpc.beginOrder == ["file-0.bin"])
        #expect(await rpc.chunkOffsets["file-0.bin"] == [0, ChunkUploadLimits.rawChunkBytes])
        #expect(await rpc.methods.filter { $0 == RemoteRPCMethod.uploadCommit.rawValue }.isEmpty)

        uploadTask.cancel()
        do {
            _ = try await uploadTask.value
            Issue.record("the blocked upload must observe cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test
    func uncooperativeRelayCancelReturnsAtVirtualDeadlineAndDrainsAfterLateResponse() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let staged = try files.prepared(
            ordinal: 0,
            byteCount: Int64(ChunkUploadLimits.rawChunkBytes + 1)
        )
        let replacement = try files.prepared(ordinal: 1, byteCount: 1, filename: "replacement.bin")
        let chunkGate = CancellableCallGate()
        let relayCancel = UncooperativeCancellationProbe()
        let deadline = VirtualCancellationDeadline()
        let rpc = UploadRPCFixture(
            blockFilename: staged.filename,
            blockChunkOffset: ChunkUploadLimits.rawChunkBytes,
            chunkGate: chunkGate,
            uncooperativeRelayCancel: relayCancel
        )
        let uploader = AttachmentUploader(
            rpc: rpc,
            cancellationDeadline: { try await deadline.sleep() }
        )
        var blockedChunks = await chunkGate.starts().makeAsyncIterator()
        var relayStarts = await relayCancel.starts().makeAsyncIterator()
        var deadlineStarts = await deadline.starts().makeAsyncIterator()
        var deadlineDrains = await deadline.drains().makeAsyncIterator()
        let uploadTask = Task {
            try await uploader.upload(
                staged,
                batchID: UUID().uuidString,
                batchFileCount: 1,
                batchBytes: Int(staged.bytes)
            ) { _ in }
        }

        _ = await blockedChunks.next()
        let cancelTask = Task { await uploader.cancelCurrentUpload() }
        _ = await relayStarts.next()
        _ = await deadlineStarts.next()
        await deadline.advance()
        _ = await deadlineDrains.next()
        await cancelTask.value

        #expect(await uploader.pendingCancellationOperationCount == 1)
        uploadTask.cancel()
        _ = try? await uploadTask.value
        let replacementResult = try await uploader.upload(
            replacement,
            batchID: UUID().uuidString,
            batchFileCount: 1,
            batchBytes: Int(replacement.bytes)
        ) { _ in }
        #expect(replacementResult.filename == replacement.filename)

        let drainTask = Task { await uploader.waitForCancellationOperationsToDrain() }
        await relayCancel.release()
        await drainTask.value
        #expect(await uploader.pendingCancellationOperationCount == 0)
        #expect(await relayCancel.activeCount == 0)
        #expect(await rpc.cancelledUploadIDs == ["upload-file-0.bin"])
    }

    @Test
    func fastRelayCancelReturnsBeforeDeadlineAndRepeatedCancelStartsNoTask() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let staged = try files.prepared(
            ordinal: 0,
            byteCount: Int64(ChunkUploadLimits.rawChunkBytes + 1)
        )
        let chunkGate = CancellableCallGate()
        let deadline = VirtualCancellationDeadline()
        let rpc = UploadRPCFixture(
            blockFilename: staged.filename,
            blockChunkOffset: ChunkUploadLimits.rawChunkBytes,
            chunkGate: chunkGate
        )
        let uploader = AttachmentUploader(
            rpc: rpc,
            cancellationDeadline: { try await deadline.sleep() }
        )
        var blockedChunks = await chunkGate.starts().makeAsyncIterator()
        let uploadTask = Task {
            try await uploader.upload(
                staged,
                batchID: UUID().uuidString,
                batchFileCount: 1,
                batchBytes: Int(staged.bytes)
            ) { _ in }
        }

        _ = await blockedChunks.next()
        await uploader.cancelCurrentUpload()
        await uploader.cancelCurrentUpload()
        await uploader.waitForCancellationOperationsToDrain()

        #expect(await rpc.cancelledUploadIDs == ["upload-file-0.bin"])
        #expect(await deadline.advanceCount == 0)
        #expect(await deadline.pendingCount == 0)
        let deadlineStartCount = await deadline.startCount
        let deadlineDrainCount = await deadline.drainCount
        #expect(deadlineStartCount <= 1)
        #expect(deadlineStartCount == deadlineDrainCount)

        uploadTask.cancel()
        do {
            _ = try await uploadTask.value
            Issue.record("the blocked upload must observe cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test
    func callerCancellationDrainsRelayAndDeadlineBranches() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let staged = try files.prepared(
            ordinal: 0,
            byteCount: Int64(ChunkUploadLimits.rawChunkBytes + 1)
        )
        let chunkGate = CancellableCallGate()
        let relayCancel = CancellationCooperativeProbe()
        let deadline = VirtualCancellationDeadline()
        let rpc = UploadRPCFixture(
            blockFilename: staged.filename,
            blockChunkOffset: ChunkUploadLimits.rawChunkBytes,
            chunkGate: chunkGate,
            relayCancel: relayCancel
        )
        let uploader = AttachmentUploader(
            rpc: rpc,
            cancellationDeadline: { try await deadline.sleep() }
        )
        var blockedChunks = await chunkGate.starts().makeAsyncIterator()
        var relayStarts = await relayCancel.starts().makeAsyncIterator()
        var relayDrains = await relayCancel.drains().makeAsyncIterator()
        var deadlineStarts = await deadline.starts().makeAsyncIterator()
        var deadlineDrains = await deadline.drains().makeAsyncIterator()
        let uploadTask = Task {
            try await uploader.upload(
                staged,
                batchID: UUID().uuidString,
                batchFileCount: 1,
                batchBytes: Int(staged.bytes)
            ) { _ in }
        }

        _ = await blockedChunks.next()
        let cancelTask = Task { await uploader.cancelCurrentUpload() }
        _ = await relayStarts.next()
        _ = await deadlineStarts.next()
        cancelTask.cancel()
        _ = await relayDrains.next()
        _ = await deadlineDrains.next()
        await cancelTask.value

        let relayStartCount = await relayCancel.startCount
        let relayDrainCount = await relayCancel.drainCount
        let deadlineStartCount = await deadline.startCount
        let deadlineDrainCount = await deadline.drainCount
        #expect(await relayCancel.activeCount == 0)
        #expect(relayStartCount == relayDrainCount)
        #expect(await deadline.pendingCount == 0)
        #expect(await deadline.advanceCount == 0)
        #expect(deadlineStartCount == deadlineDrainCount)

        uploadTask.cancel()
        do {
            _ = try await uploadTask.value
            Issue.record("the blocked upload must observe cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test
    func repeatedStartCannotReplaceActiveBatch() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let chunkGate = CancellableCallGate()
        let rpc = UploadRPCFixture(
            blockFilename: "file-0.bin",
            blockChunkOffset: 0,
            chunkGate: chunkGate
        )
        let store = AttachmentStore(
            rpc: rpc,
            prepare: { selection, ordinal in
                try files.prepared(
                    ordinal: ordinal,
                    byteCount: 1,
                    filename: selection.url.lastPathComponent
                )
            }
        )
        var blockedChunks = await chunkGate.starts().makeAsyncIterator()

        await store.startUpload(files.selections(count: 1), hostGeneration: 1)
        _ = await blockedChunks.next()
        await store.startUpload(
            [AttachmentSelection(url: files.sourceURL(name: "replacement.bin"))],
            hostGeneration: 1
        )

        #expect(store.isUploading)
        #expect(store.items.map(\.filename) == ["file-0.bin"])
        #expect(await rpc.beginOrder == ["file-0.bin"])

        await store.cancel()
        #expect(store.items[0].state == .cancelled)
        #expect(await rpc.beginOrder == ["file-0.bin"])
    }

    @Test
    func validOversizedValidContinuesWithSuccessfulItems() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let rpc = UploadRPCFixture()
        let store = AttachmentStore(rpc: rpc, prepare: { _, ordinal in
            if ordinal == 1 { throw AttachmentPreparationError.fileTooLarge }
            return try files.prepared(ordinal: ordinal, byteCount: 2)
        })

        await store.startUpload(files.selections(count: 3), hostGeneration: 1)
        await store.waitForCurrentOperation()

        #expect(await rpc.beginOrder == ["file-0.bin", "file-2.bin"])
        #expect(store.items[0].isSucceeded)
        #expect(store.items[1].failure?.code == "file_too_large")
        #expect(store.items[2].isSucceeded)
    }

    @Suite
    @MainActor
    struct testCancelStopsAfterCurrentChunk {
        @Test
        func behavior() async throws {
            let files = try AttachmentStoreFixture()
            defer { files.remove() }
            let staged = try [
                files.prepared(ordinal: 0, byteCount: 1),
                files.prepared(ordinal: 1, byteCount: Int64(ChunkUploadLimits.rawChunkBytes + 1)),
                files.prepared(ordinal: 2, byteCount: 1),
            ]
            let chunkGate = CancellableCallGate()
            let rpc = UploadRPCFixture(blockFilename: "file-1.bin", blockChunkOffset: 0, chunkGate: chunkGate)
            let store = AttachmentStore(rpc: rpc, prepare: { _, ordinal in staged[ordinal] })
            var blockedCalls = await chunkGate.starts().makeAsyncIterator()

            await store.startUpload(files.selections(count: 3), hostGeneration: 1)
            _ = await blockedCalls.next()
            await store.cancel()
            await store.cancel()

            #expect(await rpc.beginOrder == ["file-0.bin", "file-1.bin"])
            #expect(await rpc.chunkOffsets["file-1.bin"] == [0])
            #expect(await rpc.cancelledUploadIDs == ["upload-file-1.bin"])
            #expect(store.quotedPaths == ["'/Users/test/Downloads/file-0.bin'"])
            #expect(store.items[0].isSucceeded)
            #expect(store.items[1].state == .cancelled)
            #expect(store.items[2].state == .unattempted)
            #expect(store.items[1].isCancelled)
            #expect(store.items[2].isCancelled)
            #expect(!FileManager.default.fileExists(atPath: staged[1].stagedURL.path))
            #expect(!FileManager.default.fileExists(atPath: staged[2].stagedURL.path))
        }
    }

    @Test
    func activeUploadCannotDismissResults() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let staged = try files.prepared(ordinal: 0, byteCount: 2)
        let chunkGate = CancellableCallGate()
        let rpc = UploadRPCFixture(
            blockFilename: staged.filename,
            blockChunkOffset: 0,
            chunkGate: chunkGate
        )
        let store = AttachmentStore(rpc: rpc, prepare: { _, _ in staged })
        var blockedChunks = await chunkGate.starts().makeAsyncIterator()

        await store.startUpload(files.selections(count: 1), hostGeneration: 1)
        _ = await blockedChunks.next()

        #expect(!store.dismissResults())
        #expect(store.isUploading)
        #expect(store.items.count == 1)
        #expect(FileManager.default.fileExists(atPath: staged.stagedURL.path))

        await store.cancel()
    }

    @Test
    func completedResultsDismissWithoutRemovingMergedDraftOrCachedCapability() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let rpc = UploadRPCFixture()
        let store = AttachmentStore(rpc: rpc, prepare: { _, ordinal in
            try files.prepared(ordinal: ordinal, byteCount: 1)
        })
        let coordinator = AttachmentCoordinator(
            store: store,
            photoStager: AttachmentStoreTestPhotoStager()
        )

        await store.startUpload(files.selections(count: 1), hostGeneration: 1)
        await store.waitForCurrentOperation()
        let quotedPath = try #require(store.quotedPaths.first)
        let mergedDraft = try #require(coordinator.mergedDraft(
            currentDraft: "echo",
            quotedPaths: store.quotedPaths
        ))

        #expect(store.dismissResults())
        #expect(store.items.isEmpty)
        #expect(store.progress == AttachmentBatchProgress())
        #expect(store.batchFailure == nil)
        #expect(store.totalAcknowledgedBytes == 0)
        #expect(store.quotedPaths.isEmpty)
        #expect(mergedDraft == "echo \(quotedPath)")
        #expect(coordinator.mergedDraft(currentDraft: mergedDraft, quotedPaths: store.quotedPaths) == nil)

        await store.startUpload(files.selections(count: 1), hostGeneration: 1)
        await store.waitForCurrentOperation()
        #expect(await rpc.methods.filter { $0 == RemoteRPCMethod.hostCapabilities.rawValue }.count == 1)
    }

    @Test
    func failedRetryResultsDismissAndDeleteStagedFiles() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let staged = try files.prepared(
            ordinal: 0,
            byteCount: Int64(ChunkUploadLimits.rawChunkBytes + 1)
        )
        let rpc = UploadRPCFixture(
            failChunkAtOffset: [staged.filename: ChunkUploadLimits.rawChunkBytes]
        )
        let store = AttachmentStore(rpc: rpc, prepare: { _, _ in staged })

        await store.startUpload(files.selections(count: 1), hostGeneration: 1)
        await store.waitForCurrentOperation()

        #expect(store.canRetryFailed)
        #expect(store.totalAcknowledgedBytes == Int64(ChunkUploadLimits.rawChunkBytes))
        #expect(FileManager.default.fileExists(atPath: staged.stagedURL.path))

        #expect(store.dismissResults())
        #expect(store.items.isEmpty)
        #expect(store.progress == AttachmentBatchProgress())
        #expect(store.batchFailure == nil)
        #expect(store.totalAcknowledgedBytes == 0)
        #expect(!store.canRetryFailed)
        #expect(!FileManager.default.fileExists(atPath: staged.stagedURL.path))
    }

    @Test
    func partialFailureContinuesAndRetainsRetryState() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let staged = try (0..<3).map { try files.prepared(ordinal: $0, byteCount: 2) }
        let rpc = UploadRPCFixture(failChunkOnceFor: ["file-1.bin"])
        let store = AttachmentStore(rpc: rpc, prepare: { _, ordinal in staged[ordinal] })

        await store.startUpload(files.selections(count: 3), hostGeneration: 1)
        await store.waitForCurrentOperation()

        #expect(store.quotedPaths == [
            "'/Users/test/Downloads/file-0.bin'",
            "'/Users/test/Downloads/file-2.bin'",
        ])
        #expect(store.items[1].failure?.retryable == true)
        #expect(FileManager.default.fileExists(atPath: staged[1].stagedURL.path))
        #expect(await rpc.beginOrder == ["file-0.bin", "file-1.bin", "file-2.bin"])
    }

    @Test
    func missingCapabilityRequiresUpdateAndNeverUsesLegacyUpload() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let rpc = UploadRPCFixture(capabilities: [])
        let store = AttachmentStore(rpc: rpc, prepare: { _, ordinal in
            try files.prepared(ordinal: ordinal, byteCount: 1)
        })

        await store.startUpload(files.selections(count: 1), hostGeneration: 1)
        await store.waitForCurrentOperation()

        #expect(store.capabilityState == .updateRequired)
        #expect(store.batchFailure?.code == "update_required")
        #expect(await rpc.methods == [RemoteRPCMethod.hostCapabilities.rawValue])
    }

    @Suite
    @MainActor
    struct testLateResponseAfterHostChangeIsIgnored {
        @Test
        func behavior() async throws {
            let files = try AttachmentStoreFixture()
            defer { files.remove() }
            let capabilityGate = LateCapabilityGate()
            let rpc = UploadRPCFixture(capabilityGate: capabilityGate)
            let store = AttachmentStore(rpc: rpc, prepare: { _, ordinal in
                try files.prepared(ordinal: ordinal, byteCount: 1)
            })
            var capabilityStarts = await capabilityGate.starts().makeAsyncIterator()

            await store.startUpload(files.selections(count: 1), hostGeneration: 1)
            _ = await capabilityStarts.next()
            await store.setHostGeneration(2)
            await capabilityGate.release(capabilities: [HostCapabilities.chunkUploadV2])
            await store.waitForCurrentOperation()

            #expect(store.hostGeneration == 2)
            #expect(store.capabilityState == .unknown)
            #expect(store.items.isEmpty)
            #expect(store.quotedPaths.isEmpty)
            #expect(await rpc.beginOrder.isEmpty)
        }
    }

    @Test(arguments: [UploadRPCFixture.InvalidCommit.hash, .path, .size])
    func malformedCommitResultFailsItemAndInsertsNoPath(invalid: UploadRPCFixture.InvalidCommit) async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let staged = try files.prepared(ordinal: 0, byteCount: 3)
        let rpc = UploadRPCFixture(invalidCommit: ["file-0.bin": invalid])
        let store = AttachmentStore(rpc: rpc, prepare: { _, _ in staged })

        await store.startUpload(files.selections(count: 1), hostGeneration: 1)
        await store.waitForCurrentOperation()

        #expect(store.items[0].failure?.code == "invalid_server_result")
        #expect(store.quotedPaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: staged.stagedURL.path))
    }

    @Test
    func retryUsesStagedFileThenCleansItAndRestoresOrdinalPathOrder() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let staged = try (0..<2).map { try files.prepared(ordinal: $0, byteCount: 2) }
        let rpc = UploadRPCFixture(failChunkOnceFor: ["file-0.bin"])
        let batchID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000099"))
        let store = AttachmentStore(
            rpc: rpc,
            prepare: { _, ordinal in staged[ordinal] },
            batchIDSource: { batchID }
        )

        await store.startUpload(files.selections(count: 2), hostGeneration: 1)
        await store.waitForCurrentOperation()
        #expect(store.quotedPaths == ["'/Users/test/Downloads/file-1.bin'"])

        await store.retryFailed()
        await store.waitForCurrentOperation()

        #expect(store.quotedPaths == [
            "'/Users/test/Downloads/file-0.bin'",
            "'/Users/test/Downloads/file-1.bin'",
        ])
        #expect(!FileManager.default.fileExists(atPath: staged[0].stagedURL.path))
        #expect(await rpc.beginOrder == ["file-0.bin", "file-1.bin", "file-0.bin"])
        #expect(await rpc.beginRequests.allSatisfy {
            $0.batchId == batchID.uuidString && $0.batchFileCount == 2 && $0.batchBytes == 4
        })
        #expect(await rpc.methods.filter { $0 == RemoteRPCMethod.hostCapabilities.rawValue }.count == 1)
    }

    @Test
    func quotesMixedDocumentAndUnknownServerPathsInPickerOrder() async throws {
        let files = try AttachmentStoreFixture()
        defer { files.remove() }
        let names = ["a.pdf", "b.docx", "c.hwp", "d.hwpx", "e.zip", "f.unknown"]
        let paths = Dictionary(uniqueKeysWithValues: names.enumerated().map {
            ($0.element, "/Users/test/Drop/\($0.offset)-it's \($0.element)")
        })
        let rpc = UploadRPCFixture(paths: paths)
        let store = AttachmentStore(rpc: rpc, prepare: { selection, ordinal in
            try files.prepared(ordinal: ordinal, byteCount: 1, filename: selection.url.lastPathComponent)
        })
        let selections = names.map { AttachmentSelection(url: files.sourceURL(name: $0)) }

        await store.startUpload(selections, hostGeneration: 1)
        await store.waitForCurrentOperation()

        #expect(store.quotedPaths == names.enumerated().map {
            "'/Users/test/Drop/\($0.offset)-it'\\''s \($0.element)'"
        })
    }
}

private struct AttachmentStoreTestPhotoStager: AttachmentPhotoStaging {
    func stage(_ data: Data) async throws -> AttachmentSelection {
        throw AttachmentPhotoStagingError.invalidImage
    }

    func remove(_ selection: AttachmentSelection) async {}
}

private struct AttachmentStoreFixture: Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func selections(count: Int) -> [AttachmentSelection] {
        (0..<count).map { AttachmentSelection(url: sourceURL(name: "file-\($0).bin")) }
    }

    func sourceURL(name: String) -> URL {
        root.appendingPathComponent(name)
    }

    func prepared(ordinal: Int, byteCount: Int64, sparse: Bool = false, filename: String? = nil) throws -> PreparedAttachment {
        let url = root.appendingPathComponent("staged-\(ordinal)-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        if sparse {
            try handle.truncate(atOffset: UInt64(byteCount))
        } else if byteCount > 0 {
            let block = Data(repeating: UInt8(ordinal + 1), count: min(Int(byteCount), 1024 * 1024))
            var remaining = byteCount
            while remaining > 0 {
                let count = min(Int64(block.count), remaining)
                try handle.write(contentsOf: block.prefix(Int(count)))
                remaining -= count
            }
        }
        try handle.close()
        let digestCharacter = String(format: "%x", ordinal % 16)
        return PreparedAttachment(
            ordinal: ordinal,
            filename: filename ?? "file-\(ordinal).bin",
            mimeType: "application/octet-stream",
            bytes: byteCount,
            sha256: String(repeating: digestCharacter, count: 64),
            stagedURL: url
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

enum StagingInvalidator: CaseIterable, Sendable {
    case cancel
    case hostGeneration
}

// FileManager cleanup is synchronous and the continuation is thread-safe, so this test observer adds no mutable shared state.
private final class RemovalRecordingFileManager: FileManager {
    private let removalStream: AsyncStream<URL>
    private let removalContinuation: AsyncStream<URL>.Continuation

    override init() {
        (removalStream, removalContinuation) = AsyncStream.makeStream(of: URL.self)
        super.init()
    }

    func removals() -> AsyncStream<URL> { removalStream }

    override func removeItem(at URL: URL) throws {
        try super.removeItem(at: URL)
        removalContinuation.yield(URL)
    }
}

// The injected UUID callback is synchronous; NSLock guards only the tiny mutable test-only sequence/index, serializing all access, so unchecked Sendable is safe.
private final class BatchIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [UUID]
    private var index = 0

    init(_ values: [UUID]) {
        self.values = values
    }

    var consumedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        precondition(index < values.count, "BatchIDSequence exhausted")
        let value = values[index]
        index += 1
        return value
    }
}

private actor StagingCompletionGate {
    private let prepared: [PreparedAttachment]
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private let startStream: AsyncStream<Int>
    private let startContinuation: AsyncStream<Int>.Continuation

    init(prepared: [PreparedAttachment]) {
        self.prepared = prepared
        (startStream, startContinuation) = AsyncStream.makeStream(of: Int.self)
    }

    func starts() -> AsyncStream<Int> { startStream }

    func prepare(selection: AttachmentSelection, ordinal: Int) async throws -> PreparedAttachment {
        startContinuation.yield(ordinal)
        await withCheckedContinuation { waiters[ordinal] = $0 }
        return prepared[ordinal]
    }

    func release(ordinal: Int) {
        waiters.removeValue(forKey: ordinal)?.resume()
    }

    func releaseAll() {
        let continuations = Array(waiters.values)
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

actor CancellableCallGate {
    private var waiter: CheckedContinuation<Void, Error>?
    private let startStream: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation

    init() {
        (startStream, startContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func starts() -> AsyncStream<Void> { startStream }

    func wait() async throws {
        startContinuation.yield(())
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
                if Task.isCancelled {
                    waiter = nil
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }

    private func cancel() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}

actor UncooperativeCancellationProbe {
    private var continuation: CheckedContinuation<Void, Never>?
    private let startStream: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private(set) var activeCount = 0

    init() {
        (startStream, startContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func starts() -> AsyncStream<Void> { startStream }

    func wait() async {
        activeCount += 1
        startContinuation.yield(())
        await withCheckedContinuation { continuation = $0 }
        activeCount -= 1
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

actor CancellationCooperativeProbe {
    private let startStream: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private let drainStream: AsyncStream<Void>
    private let drainContinuation: AsyncStream<Void>.Continuation
    private(set) var startCount = 0
    private(set) var drainCount = 0
    private(set) var activeCount = 0

    init() {
        (startStream, startContinuation) = AsyncStream.makeStream(of: Void.self)
        (drainStream, drainContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func starts() -> AsyncStream<Void> { startStream }
    func drains() -> AsyncStream<Void> { drainStream }

    func waitUntilCancelled() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        startCount += 1
        activeCount += 1
        startContinuation.yield(())
        defer {
            activeCount -= 1
            drainCount += 1
            drainContinuation.yield(())
        }
        await withTaskCancellationHandler {
            for await _ in stream {}
        } onCancel: {
            continuation.finish()
        }
        try Task.checkCancellation()
        throw FixtureRPCError.rejected
    }
}

private actor VirtualCancellationDeadline {
    private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let startStream: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private let drainStream: AsyncStream<Void>
    private let drainContinuation: AsyncStream<Void>.Continuation
    private(set) var startCount = 0
    private(set) var drainCount = 0
    private(set) var advanceCount = 0

    init() {
        (startStream, startContinuation) = AsyncStream.makeStream(of: Void.self)
        (drainStream, drainContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    var pendingCount: Int { waiters.count }

    func starts() -> AsyncStream<Void> { startStream }
    func drains() -> AsyncStream<Void> { drainStream }

    func sleep() async throws {
        let token = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        waiters[token] = continuation
        startCount += 1
        startContinuation.yield(())
        defer {
            waiters[token] = nil
            drainCount += 1
            drainContinuation.yield(())
        }
        try await withTaskCancellationHandler {
            var iterator = stream.makeAsyncIterator()
            guard await iterator.next() != nil else { throw CancellationError() }
            try Task.checkCancellation()
        } onCancel: {
            continuation.finish()
        }
    }

    func advance() {
        advanceCount += 1
        let continuations = Array(waiters.values)
        waiters.removeAll()
        for continuation in continuations {
            continuation.yield(())
            continuation.finish()
        }
    }
}

actor LateCapabilityGate {
    private var waiter: CheckedContinuation<[String], Never>?
    private let startStream: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation

    init() {
        (startStream, startContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func starts() -> AsyncStream<Void> { startStream }

    func wait() async -> [String] {
        startContinuation.yield(())
        return await withCheckedContinuation { waiter = $0 }
    }

    func release(capabilities: [String]) {
        waiter?.resume(returning: capabilities)
        waiter = nil
    }
}

actor UploadRPCFixture: RPCDispatch {
    enum InvalidCommit: Sendable {
        case hash
        case path
        case size
    }

    private let capabilities: [String]
    private let failChunkOnceFor: Set<String>
    private var remainingChunkFailures: Set<String>
    private let invalidCommit: [String: InvalidCommit]
    private let paths: [String: String]
    private let blockFilename: String?
    private let blockChunkOffset: Int?
    private let chunkGate: CancellableCallGate?
    private let capabilityGate: LateCapabilityGate?
    private let relayCancel: CancellationCooperativeProbe?
    private let uncooperativeRelayCancel: UncooperativeCancellationProbe?
    private let rejectAllBegins: Bool
    private var mismatchedBeginBatchIDOnce: String?
    private var failChunkAtOffset: [String: Int]
    private var uploadFilename: [String: String] = [:]
    private var uploadHash: [String: String] = [:]

    private(set) var methods: [String] = []
    private(set) var beginOrder: [String] = []
    private(set) var beginRequests: [ChunkUploadBeginRequest] = []
    private(set) var chunkSizes: [Int] = []
    private(set) var chunkOffsets: [String: [Int]] = [:]
    private(set) var cancelledUploadIDs: [String] = []
    private var receivedBytes: [String: Int] = [:]

    init(
        capabilities: [String] = [HostCapabilities.chunkUploadV2],
        failChunkOnceFor: Set<String> = [],
        invalidCommit: [String: InvalidCommit] = [:],
        paths: [String: String] = [:],
        blockFilename: String? = nil,
        blockChunkOffset: Int? = nil,
        chunkGate: CancellableCallGate? = nil,
        capabilityGate: LateCapabilityGate? = nil,
        relayCancel: CancellationCooperativeProbe? = nil,
        uncooperativeRelayCancel: UncooperativeCancellationProbe? = nil,
        rejectAllBegins: Bool = false,
        mismatchedBeginBatchIDOnce: String? = nil,
        failChunkAtOffset: [String: Int] = [:]
    ) {
        self.capabilities = capabilities
        self.failChunkOnceFor = failChunkOnceFor
        remainingChunkFailures = failChunkOnceFor
        self.invalidCommit = invalidCommit
        self.paths = paths
        self.blockFilename = blockFilename
        self.blockChunkOffset = blockChunkOffset
        self.chunkGate = chunkGate
        self.capabilityGate = capabilityGate
        self.relayCancel = relayCancel
        self.uncooperativeRelayCancel = uncooperativeRelayCancel
        self.rejectAllBegins = rejectAllBegins
        self.mismatchedBeginBatchIDOnce = mismatchedBeginBatchIDOnce
        self.failChunkAtOffset = failChunkAtOffset
    }

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        methods.append(method)
        switch method {
        case RemoteRPCMethod.hostCapabilities.rawValue:
            let values = if let capabilityGate { await capabilityGate.wait() } else { capabilities }
            return try response(HostCapabilitiesResult(capabilities: values))
        case RemoteRPCMethod.uploadBegin.rawValue:
            let request = try params.decode(ChunkUploadBeginRequest.self)
            beginOrder.append(request.filename)
            beginRequests.append(request)
            if rejectAllBegins { throw FixtureRPCError.rejected }
            let uploadID = "upload-\(request.filename)"
            uploadFilename[uploadID] = request.filename
            uploadHash[uploadID] = request.sha256
            let responseBatchID = mismatchedBeginBatchIDOnce ?? request.batchId
            mismatchedBeginBatchIDOnce = nil
            return try response(ChunkUploadBeginResult(uploadId: uploadID, batchId: responseBatchID))
        case RemoteRPCMethod.uploadChunk.rawValue:
            let request = try params.decode(ChunkUploadChunkRequest.self)
            let filename = uploadFilename[request.uploadId] ?? "unknown"
            let bytes = try request.decodedBytes()
            chunkSizes.append(bytes.count)
            chunkOffsets[filename, default: []].append(request.offset)
            receivedBytes[filename] = max(receivedBytes[filename] ?? 0, request.offset + bytes.count)
            if remainingChunkFailures.remove(filename) != nil
                || failChunkAtOffset[filename] == request.offset
            {
                failChunkAtOffset[filename] = nil
                throw FixtureRPCError.rejected
            }
            if (blockFilename == nil || blockFilename == filename), blockChunkOffset == request.offset, let chunkGate {
                try await chunkGate.wait()
            }
            return try response(ChunkUploadChunkResult(
                uploadId: request.uploadId,
                nextOffset: request.offset + bytes.count,
                receivedBytes: request.offset + bytes.count
            ))
        case RemoteRPCMethod.uploadCommit.rawValue:
            let request = try params.decode(ChunkUploadCommitRequest.self)
            let filename = uploadFilename[request.uploadId] ?? "unknown"
            let bytes = receivedBytes[filename] ?? 0
            let expectedHash = uploadHash[request.uploadId] ?? String(repeating: "0", count: 64)
            let invalid = invalidCommit[filename]
            return try response(ChunkUploadCommitResult(
                uploadId: request.uploadId,
                filename: filename,
                path: invalid == .path ? "relative/path" : (paths[filename] ?? "/Users/test/Downloads/\(filename)"),
                bytes: invalid == .size ? bytes + 1 : bytes,
                mimeType: "application/octet-stream",
                sha256: invalid == .hash ? String(repeating: "f", count: 64) : expectedHash
            ))
        case RemoteRPCMethod.uploadCancel.rawValue:
            let request = try params.decode(ChunkUploadCancelRequest.self)
            cancelledUploadIDs.append(request.uploadId)
            if let relayCancel { try await relayCancel.waitUntilCancelled() }
            if let uncooperativeRelayCancel { await uncooperativeRelayCancel.wait() }
            return try response(ChunkUploadCancelResult(uploadId: request.uploadId))
        default:
            throw FixtureRPCError.unexpectedMethod(method)
        }
    }

    private func response<Payload: Encodable>(_ payload: Payload) throws -> RPCResponse {
        let data = try SharedKitJSON.snakeCaseEncoder.encode(payload)
        let result = try JSONDecoder().decode(JSONValue.self, from: data)
        return RPCResponse(id: UUID().uuidString, result: result)
    }
}

private enum FixtureRPCError: Error {
    case rejected
    case unexpectedMethod(String)
}
