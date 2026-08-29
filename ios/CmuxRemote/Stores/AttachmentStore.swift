import Foundation
import Observation
import SharedKit

typealias AttachmentPreparation = @Sendable (AttachmentSelection, Int) async throws -> PreparedAttachment
typealias AttachmentBatchIDSource = @Sendable () -> UUID

@MainActor
@Observable
final class AttachmentStore {
    private let rpc: any RPCDispatch
    private let uploader: AttachmentUploader
    private let prepare: AttachmentPreparation
    private let batchIDSource: AttachmentBatchIDSource
    private let fileManager: FileManager

    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var preparedByOrdinal: [Int: PreparedAttachment] = [:]
    @ObservationIgnored private var acknowledgedBytes: [Int: Int64] = [:]
    @ObservationIgnored private var cachedCapabilities: HostCapabilitiesResult?
    @ObservationIgnored private var cachedCapabilityGeneration: Int?
    @ObservationIgnored private var activeBatchID: String?
    @ObservationIgnored private var activeBatchFileCount = 0
    @ObservationIgnored private var activeBatchBytes = 0

    private(set) var hostGeneration = 0
    private(set) var capabilityState: AttachmentCapabilityState = .unknown
    private(set) var items: [AttachmentItem] = []
    private(set) var progress = AttachmentBatchProgress()
    private(set) var batchFailure: AttachmentItemFailure?
    private(set) var isUploading = false

    var quotedPaths: [String] {
        items.sorted { $0.ordinal < $1.ordinal }.compactMap { item in
            guard case .succeeded(_, let quotedPath) = item.state else { return nil }
            return quotedPath
        }
    }

    var canRetryFailed: Bool {
        items.contains { item in
            item.failure?.retryable == true && preparedByOrdinal[item.ordinal] != nil
        }
    }

    var totalAcknowledgedBytes: Int64 {
        acknowledgedBytes.values.reduce(0, +)
    }

    func acknowledgedBytes(for ordinal: Int) -> Int64 {
        acknowledgedBytes[ordinal] ?? 0
    }

    init(
        rpc: any RPCDispatch,
        prepare: @escaping AttachmentPreparation = { selection, ordinal in
            let prepared = try await AttachmentPreparer().prepare([selection])
            guard let item = prepared.first else { throw AttachmentPreparationError.stagingFailed }
            return PreparedAttachment(
                ordinal: ordinal,
                filename: item.filename,
                mimeType: item.mimeType,
                bytes: item.bytes,
                sha256: item.sha256,
                stagedURL: item.stagedURL
            )
        },
        batchIDSource: @escaping AttachmentBatchIDSource = { UUID() },
        fileManager: FileManager = .default
    ) {
        self.rpc = rpc
        uploader = AttachmentUploader(rpc: rpc)
        self.prepare = prepare
        self.batchIDSource = batchIDSource
        self.fileManager = fileManager
    }

    func startUpload(_ selections: [AttachmentSelection], hostGeneration: Int) async {
        if self.hostGeneration != hostGeneration {
            await setHostGeneration(hostGeneration)
        } else {
            guard operationTask == nil, !isUploading else { return }
        }
        clearStagedFiles()
        operationID = UUID()
        let currentOperationID = operationID
        let batchID = batchIDSource().uuidString
        activeBatchID = batchID
        activeBatchFileCount = 0
        activeBatchBytes = 0
        batchFailure = nil
        acknowledgedBytes = [:]
        items = selections.enumerated().map {
            AttachmentItem(
                ordinal: $0.offset,
                filename: $0.element.url.lastPathComponent,
                bytes: nil,
                state: $0.offset < ChunkUploadLimits.maxBatchFiles
                    ? .staging
                    : .failed(AttachmentItemFailure(
                        code: "file_count_limit",
                        message: "A batch can contain at most \(ChunkUploadLimits.maxBatchFiles) files.",
                        retryable: false
                    ))
            )
        }
        progress = AttachmentBatchProgress(totalFiles: min(selections.count, ChunkUploadLimits.maxBatchFiles))
        isUploading = true
        let acceptedSelections = Array(selections.prefix(ChunkUploadLimits.maxBatchFiles))
        operationTask = Task { [weak self] in
            await self?.runUpload(
                selections: acceptedSelections,
                generation: hostGeneration,
                operationID: currentOperationID,
                batchID: batchID
            )
        }
    }

    func waitForCurrentOperation() async {
        let task = operationTask
        await task?.value
    }

    func cancel() async {
        guard let operationTask else { return }
        operationID = UUID()
        self.operationTask = nil
        operationTask.cancel()
        markRemainingCancelledAndCleanUp()
        await uploader.cancelCurrentUpload()
    }

    @discardableResult
    func dismissResults() -> Bool {
        guard operationTask == nil, !isUploading else { return false }
        operationID = UUID()
        clearStagedFiles()
        acknowledgedBytes = [:]
        activeBatchID = nil
        activeBatchFileCount = 0
        activeBatchBytes = 0
        items = []
        progress = AttachmentBatchProgress()
        batchFailure = nil
        return true
    }

    func setHostGeneration(_ generation: Int) async {
        guard generation != hostGeneration else { return }
        operationID = UUID()
        let previousOperation = operationTask
        operationTask = nil
        previousOperation?.cancel()
        hostGeneration = generation
        cachedCapabilities = nil
        cachedCapabilityGeneration = nil
        activeBatchID = nil
        activeBatchFileCount = 0
        activeBatchBytes = 0
        capabilityState = .unknown
        clearStagedFiles()
        items = []
        progress = AttachmentBatchProgress()
        batchFailure = nil
        isUploading = false
        await uploader.cancelCurrentUpload()
    }

    func retryFailed() async {
        guard operationTask == nil || !isUploading else { return }
        let retryOrdinals = items.compactMap { item -> Int? in
            guard item.failure?.retryable == true, preparedByOrdinal[item.ordinal] != nil else { return nil }
            return item.ordinal
        }
        guard !retryOrdinals.isEmpty,
              let batchID = activeBatchID,
              activeBatchFileCount > 0
        else { return }
        operationID = UUID()
        let currentOperationID = operationID
        batchFailure = nil
        for ordinal in retryOrdinals {
            acknowledgedBytes[ordinal] = 0
            updateItem(ordinal: ordinal) { $0.state = .ready }
        }
        progress = AttachmentBatchProgress(
            sentBytes: totalAcknowledgedBytes,
            totalBytes: Int64(activeBatchBytes),
            completedFiles: items.filter(\.isSucceeded).count,
            totalFiles: activeBatchFileCount
        )
        isUploading = true
        let batchFileCount = activeBatchFileCount
        let batchBytes = activeBatchBytes
        operationTask = Task { [weak self] in
            await self?.runPreparedUploads(
                ordinals: retryOrdinals,
                operationID: currentOperationID,
                batchID: batchID,
                batchFileCount: batchFileCount,
                batchBytes: batchBytes
            )
        }
    }

    private func runUpload(
        selections: [AttachmentSelection],
        generation: Int,
        operationID: UUID,
        batchID: String
    ) async {
        guard await requireChunkUploadCapability(generation: generation, operationID: operationID) else {
            finish(operationID: operationID)
            return
        }
        let outcomes = await prepareSelections(selections, operationID: operationID)
        guard isCurrent(operationID), !Task.isCancelled else { return }
        for outcome in outcomes {
            if let attachment = outcome.attachment {
                updateItem(ordinal: outcome.ordinal) {
                    $0.filename = attachment.filename
                    $0.bytes = attachment.bytes
                    $0.state = .ready
                }
            } else if let failure = outcome.failure {
                updateItem(ordinal: outcome.ordinal) { $0.state = .failed(failure) }
            }
        }

        var acceptedOrdinals: [Int] = []
        var batchBytes: Int64 = 0
        for ordinal in selections.indices {
            guard let attachment = preparedByOrdinal[ordinal] else { continue }
            guard attachment.bytes >= 0,
                  attachment.bytes <= Int64(ChunkUploadLimits.maxFileBytes)
            else {
                removeStagedFile(ordinal: ordinal)
                updateItem(ordinal: ordinal) {
                    $0.state = .failed(AttachmentItemFailure(
                        code: "file_too_large",
                        message: "The attachment exceeds the per-file limit.",
                        retryable: false
                    ))
                }
                continue
            }
            batchBytes += attachment.bytes
            acceptedOrdinals.append(ordinal)
        }
        if batchBytes > Int64(ChunkUploadLimits.maxBatchBytes) {
            let failure = AttachmentItemFailure(
                code: "batch_size_limit",
                message: "The attachment batch exceeds the total byte limit.",
                retryable: false
            )
            for ordinal in acceptedOrdinals {
                removeStagedFile(ordinal: ordinal)
                updateItem(ordinal: ordinal) { $0.state = .failed(failure) }
            }
            progress = AttachmentBatchProgress()
            finish(operationID: operationID)
            return
        }
        activeBatchFileCount = acceptedOrdinals.count
        activeBatchBytes = Int(batchBytes)
        progress = AttachmentBatchProgress(totalBytes: batchBytes, totalFiles: acceptedOrdinals.count)
        await runPreparedUploads(
            ordinals: acceptedOrdinals,
            operationID: operationID,
            batchID: batchID,
            batchFileCount: activeBatchFileCount,
            batchBytes: activeBatchBytes
        )
    }

    private func prepareSelections(
        _ selections: [AttachmentSelection],
        operationID: UUID
    ) async -> [AttachmentPreparationOutcome] {
        await withTaskGroup(of: AttachmentPreparationOutcome.self) { group in
            var nextOrdinal = 0
            let initialCount = min(3, selections.count)
            for ordinal in 0..<initialCount {
                addPreparation(ordinal: ordinal, selections: selections, to: &group)
                nextOrdinal += 1
            }
            var outcomes: [AttachmentPreparationOutcome] = []
            while let outcome = await group.next() {
                let stillCurrent = isCurrent(operationID) && !Task.isCancelled
                if let attachment = outcome.attachment {
                    if stillCurrent {
                        preparedByOrdinal[outcome.ordinal] = attachment
                    } else {
                        discardStagedFile(attachment)
                    }
                }
                guard stillCurrent else {
                    group.cancelAll()
                    continue
                }
                outcomes.append(outcome)
                if nextOrdinal < selections.count {
                    addPreparation(ordinal: nextOrdinal, selections: selections, to: &group)
                    nextOrdinal += 1
                }
            }
            return outcomes.sorted { $0.ordinal < $1.ordinal }
        }
    }

    private func addPreparation(
        ordinal: Int,
        selections: [AttachmentSelection],
        to group: inout TaskGroup<AttachmentPreparationOutcome>
    ) {
        let prepare = prepare
        let selection = selections[ordinal]
        group.addTask {
            do {
                return AttachmentPreparationOutcome(
                    ordinal: ordinal,
                    attachment: try await prepare(selection, ordinal),
                    failure: nil
                )
            } catch {
                return AttachmentPreparationOutcome(
                    ordinal: ordinal,
                    attachment: nil,
                    failure: Self.preparationFailure(error)
                )
            }
        }
    }

    private func runPreparedUploads(
        ordinals: [Int],
        operationID: UUID,
        batchID: String,
        batchFileCount: Int,
        batchBytes: Int
    ) async {
        for ordinal in ordinals {
            guard isCurrent(operationID), !Task.isCancelled else {
                if isCurrent(operationID) { markRemainingCancelledAndCleanUp() }
                return
            }
            guard let attachment = preparedByOrdinal[ordinal] else { continue }
            updateItem(ordinal: ordinal) { $0.state = .uploading(bytesSent: 0) }
            do {
                let committed = try await uploader.upload(
                    attachment,
                    batchID: batchID,
                    batchFileCount: batchFileCount,
                    batchBytes: batchBytes
                ) { [weak self] bytes in
                    await self?.recordProgress(bytes, ordinal: ordinal, operationID: operationID)
                }
                guard isCurrent(operationID), !Task.isCancelled else { return }
                removeStagedFile(ordinal: ordinal)
                updateItem(ordinal: ordinal) {
                    $0.state = .succeeded(
                        path: committed.path,
                        quotedPath: ShellPathQuoter.quote(committed.path)
                    )
                }
                progress.completedFiles += 1
            } catch is CancellationError {
                if isCurrent(operationID) { markRemainingCancelledAndCleanUp() }
                return
            } catch {
                guard isCurrent(operationID) else { return }
                updateItem(ordinal: ordinal) {
                    $0.state = .failed(Self.uploadFailure(error))
                }
                progress.completedFiles += 1
            }
        }
        finish(operationID: operationID)
    }

    private func requireChunkUploadCapability(generation: Int, operationID: UUID) async -> Bool {
        if cachedCapabilityGeneration == generation, let cachedCapabilities {
            capabilityState = cachedCapabilities.supportsChunkUploadV2 ? .available : .updateRequired
            return cachedCapabilities.supportsChunkUploadV2
        }
        do {
            let data = try SharedKitJSON.snakeCaseEncoder.encode(HostCapabilitiesRequest())
            let params = try JSONDecoder().decode(JSONValue.self, from: data)
            let response = try await rpc.call(method: RemoteRPCMethod.hostCapabilities.rawValue, params: params)
            let capabilities = try response.decodeResult(HostCapabilitiesResult.self)
            guard isCurrent(operationID), hostGeneration == generation, !Task.isCancelled else { return false }
            cachedCapabilities = capabilities
            cachedCapabilityGeneration = generation
            if capabilities.supportsChunkUploadV2 {
                capabilityState = .available
                return true
            }
            capabilityState = .updateRequired
            batchFailure = AttachmentItemFailure(
                code: "update_required",
                message: "Update the Mac relay to upload attachments.",
                retryable: false
            )
            markAllPendingFailed(with: batchFailure!)
            return false
        } catch {
            guard isCurrent(operationID), hostGeneration == generation, !Task.isCancelled else { return false }
            let failure = AttachmentItemFailure(
                code: "capability_failed",
                message: String(describing: error),
                retryable: true
            )
            batchFailure = failure
            markAllPendingFailed(with: failure)
            return false
        }
    }

    private func recordProgress(_ bytes: Int64, ordinal: Int, operationID: UUID) {
        guard isCurrent(operationID) else { return }
        acknowledgedBytes[ordinal] = bytes
        progress.sentBytes = totalAcknowledgedBytes
        progress.currentOrdinal = ordinal
        updateItem(ordinal: ordinal) { $0.state = .uploading(bytesSent: bytes) }
    }

    private func finish(operationID: UUID) {
        guard isCurrent(operationID) else { return }
        isUploading = false
        progress.currentOrdinal = nil
        operationTask = nil
    }

    private func isCurrent(_ candidate: UUID) -> Bool {
        operationID == candidate
    }

    private func updateItem(ordinal: Int, update: (inout AttachmentItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.ordinal == ordinal }) else { return }
        update(&items[index])
    }

    private func markAllPendingFailed(with failure: AttachmentItemFailure) {
        for index in items.indices where !items[index].isSucceeded {
            items[index].state = .failed(failure)
        }
    }

    private func markRemainingCancelledAndCleanUp() {
        for index in items.indices where !items[index].isSucceeded {
            switch items[index].state {
            case .uploading:
                items[index].state = .cancelled
            case .staging, .ready:
                items[index].state = .unattempted
            case .failed, .cancelled, .unattempted, .succeeded:
                break
            }
        }
        clearStagedFiles()
        progress.currentOrdinal = nil
        isUploading = false
    }

    private func clearStagedFiles() {
        for attachment in preparedByOrdinal.values {
            try? fileManager.removeItem(at: attachment.stagedURL)
        }
        preparedByOrdinal = [:]
    }

    private func removeStagedFile(ordinal: Int) {
        guard let attachment = preparedByOrdinal.removeValue(forKey: ordinal) else { return }
        try? fileManager.removeItem(at: attachment.stagedURL)
    }

    private func discardStagedFile(_ attachment: PreparedAttachment) {
        try? fileManager.removeItem(at: attachment.stagedURL)
    }

    nonisolated private static func preparationFailure(_ error: Error) -> AttachmentItemFailure {
        let code: String
        let retryable: Bool
        switch error as? AttachmentPreparationError {
        case .cancelled: code = "cancelled"; retryable = true
        case .fileTooLarge: code = "file_too_large"; retryable = false
        case .sourceUnavailable: code = "source_unavailable"; retryable = true
        case .stagingFailed: code = "staging_failed"; retryable = true
        case nil: code = "staging_failed"; retryable = true
        }
        return AttachmentItemFailure(code: code, message: String(describing: error), retryable: retryable)
    }

    nonisolated private static func uploadFailure(_ error: Error) -> AttachmentItemFailure {
        if let error = error as? AttachmentUploaderError {
            return AttachmentItemFailure(
                code: "invalid_server_result",
                message: String(describing: error),
                retryable: true
            )
        }
        if let error = error as? RPCError {
            return AttachmentItemFailure(code: error.code, message: error.message, retryable: true)
        }
        return AttachmentItemFailure(code: "upload_failed", message: String(describing: error), retryable: true)
    }
}

private struct AttachmentPreparationOutcome: Sendable {
    let ordinal: Int
    let attachment: PreparedAttachment?
    let failure: AttachmentItemFailure?
}
