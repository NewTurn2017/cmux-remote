import Foundation
import SharedKit

actor AttachmentUploader {
    private let rpc: any RPCDispatch
    private let cancellationDeadline: AttachmentCancellationDeadline
    private var activeUploadID: String?
    private var cancellationSent = false
    private var cancellationOperations: [UUID: AttachmentCancellationOperation] = [:]
    private var cancellationDrainWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        rpc: any RPCDispatch,
        cancellationDeadline: @escaping AttachmentCancellationDeadline = {
            // Relay cancellation is best effort and gets one bounded second to respond.
            try await ContinuousClock().sleep(for: .seconds(1))
        }
    ) {
        self.rpc = rpc
        self.cancellationDeadline = cancellationDeadline
    }

    func upload(
        _ attachment: PreparedAttachment,
        batchID: String,
        batchFileCount: Int,
        batchBytes: Int,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> ChunkUploadCommitResult {
        let begin = ChunkUploadBeginRequest(
            batchId: batchID,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            bytes: Int(attachment.bytes),
            sha256: attachment.sha256,
            batchFileCount: batchFileCount,
            batchBytes: batchBytes
        )
        let beginResult: ChunkUploadBeginResult = try await call(
            method: .uploadBegin,
            payload: begin,
            result: ChunkUploadBeginResult.self
        )
        guard !beginResult.uploadId.isEmpty,
              beginResult.batchId == batchID,
              beginResult.chunkBytes == ChunkUploadLimits.rawChunkBytes
        else {
            throw AttachmentUploaderError.invalidBeginResult
        }

        activeUploadID = beginResult.uploadId
        cancellationSent = false
        do {
            let handle = try FileHandle(forReadingFrom: attachment.stagedURL)
            defer { try? handle.close() }
            var offset = 0
            while offset < attachment.bytes {
                try Task.checkCancellation()
                guard !cancellationSent else { throw CancellationError() }
                let requestedBytes = min(
                    ChunkUploadLimits.rawChunkBytes,
                    Int(attachment.bytes - Int64(offset))
                )
                guard let data = try handle.read(upToCount: requestedBytes),
                      data.count == requestedBytes
                else {
                    throw AttachmentUploaderError.stagedFileChanged
                }
                try Task.checkCancellation()
                let chunk = ChunkUploadChunkRequest(
                    uploadId: beginResult.uploadId,
                    offset: offset,
                    dataBase64: data.base64EncodedString()
                )
                let acknowledgement: ChunkUploadChunkResult = try await call(
                    method: .uploadChunk,
                    payload: chunk,
                    result: ChunkUploadChunkResult.self
                )
                let nextOffset = offset + data.count
                guard acknowledgement.uploadId == beginResult.uploadId,
                      acknowledgement.nextOffset == nextOffset,
                      acknowledgement.receivedBytes == nextOffset
                else {
                    throw AttachmentUploaderError.invalidChunkResult
                }
                offset = nextOffset
                await progress(Int64(offset))
            }
            try Task.checkCancellation()
            guard !cancellationSent else { throw CancellationError() }
            let committed: ChunkUploadCommitResult = try await call(
                method: .uploadCommit,
                payload: ChunkUploadCommitRequest(uploadId: beginResult.uploadId),
                result: ChunkUploadCommitResult.self
            )
            guard committed.uploadId == beginResult.uploadId,
                  Int64(committed.bytes) == attachment.bytes,
                  committed.sha256.lowercased() == attachment.sha256.lowercased(),
                  committed.path.hasPrefix("/"),
                  !committed.path.contains("\0")
            else {
                throw AttachmentUploaderError.invalidCommitResult
            }
            activeUploadID = nil
            return committed
        } catch {
            if !Task.isCancelled {
                await cancelCurrentUpload()
                activeUploadID = nil
            }
            throw error
        }
    }

    func cancelCurrentUpload() async {
        guard let uploadID = activeUploadID, !cancellationSent else { return }
        cancellationSent = true
        activeUploadID = nil

        guard let data = try? SharedKitJSON.snakeCaseEncoder.encode(
            ChunkUploadCancelRequest(uploadId: uploadID)
        ), let params = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }

        let operationID = UUID()
        let signal = AttachmentCancellationSignal()
        let rpc = rpc
        let cancellationDeadline = cancellationDeadline
        let rpcTask = Task { [weak self] in
            _ = try? await rpc.call(method: RemoteRPCMethod.uploadCancel.rawValue, params: params)
            await signal.complete()
            await self?.cancellationBranchFinished(operationID, branch: .rpc)
        }
        let deadlineTask = Task { [weak self] in
            try? await cancellationDeadline()
            await signal.complete()
            await self?.cancellationBranchFinished(operationID, branch: .deadline)
        }
        cancellationOperations[operationID] = AttachmentCancellationOperation(
            rpcTask: rpcTask,
            deadlineTask: deadlineTask,
            unfinished: [.rpc, .deadline]
        )

        await withTaskCancellationHandler {
            await signal.wait()
        } onCancel: {
            Task { await signal.complete() }
        }
        cancellationOperations[operationID]?.cancel()
    }

    var pendingCancellationOperationCount: Int { cancellationOperations.count }

    func waitForCancellationOperationsToDrain() async {
        if cancellationOperations.isEmpty { return }
        await withCheckedContinuation { cancellationDrainWaiters.append($0) }
    }

    private func cancellationBranchFinished(_ operationID: UUID, branch: AttachmentCancellationBranch) {
        guard var operation = cancellationOperations[operationID] else { return }
        operation.unfinished.remove(branch)
        if operation.unfinished.isEmpty {
            cancellationOperations[operationID] = nil
            if cancellationOperations.isEmpty {
                let waiters = cancellationDrainWaiters
                cancellationDrainWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        } else {
            cancellationOperations[operationID] = operation
        }
    }

    private func call<Payload: Encodable, Result: Decodable>(
        method: RemoteRPCMethod,
        payload: Payload,
        result: Result.Type
    ) async throws -> Result {
        let data = try SharedKitJSON.snakeCaseEncoder.encode(payload)
        let params = try JSONDecoder().decode(JSONValue.self, from: data)
        let response = try await rpc.call(method: method.rawValue, params: params)
        return try response.decodeResult(result)
    }
}
