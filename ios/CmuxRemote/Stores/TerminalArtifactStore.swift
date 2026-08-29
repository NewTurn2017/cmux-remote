import Foundation
import Observation
import SharedKit

@MainActor
@Observable
final class TerminalArtifactStore {
    private(set) var identity: TerminalArtifactIdentity?
    private(set) var artifacts: [TerminalArtifact] = []
    private(set) var scanGeneration: Int?
    var selection: String?
    private(set) var state: TerminalArtifactStoreState = .idle
    private(set) var viewerURL: URL?

    private let rpc: any RPCDispatch
    private let cache: TerminalArtifactCache
    private let imageInspector: any TerminalArtifactImageInspecting
    private var identityEpoch: UInt64 = 0
    private var viewerEpoch: UInt64 = 0
    private var scanOperation: TerminalArtifactSharedOperation<TerminalArtifactScanResult>?
    private var thumbnailTasks: [TerminalArtifactThumbnailCacheKey: TerminalArtifactSharedOperation<Data>] = [:]
    private var fullTasks: [TerminalArtifactCacheKey: TerminalArtifactSharedOperation<TerminalArtifactCacheKey>] = [:]
    private var viewerTasks: [TerminalArtifactCacheKey: TerminalArtifactSharedOperation<URL>] = [:]
    private var finishedOperationIDs: Set<UUID> = []
    private var retiredOperations: [UUID: TerminalArtifactRetiredOperation] = [:]
    private var retiredDrainWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        rpc: any RPCDispatch,
        cache: TerminalArtifactCache,
        imageInspector: any TerminalArtifactImageInspecting = ImageIOTerminalArtifactImageInspector()
    ) {
        self.rpc = rpc
        self.cache = cache
        self.imageInspector = imageInspector
    }

    func activate(identity newIdentity: TerminalArtifactIdentity?) async {
        identityEpoch &+= 1
        viewerEpoch &+= 1
        let epoch = identityEpoch
        let oldViewerURL = viewerURL
        viewerURL = nil
        selection = nil
        identity = newIdentity
        artifacts = []
        scanGeneration = nil
        state = newIdentity == nil ? .idle : .loading

        await retireAllOperations()
        if let oldViewerURL { await cache.removeViewerURL(oldViewerURL) }
        guard let newIdentity else { return }

        let waiter = UUID()
        let operation = makeScanOperation(identity: newIdentity, epoch: epoch, waiter: waiter)
        scanOperation = operation
        do {
            let result = try await waitForScan(operation, waiter: waiter)
            guard isCurrent(newIdentity, epoch: epoch), scanOperation?.id == operation.id else { return }
            scanOperation = nil
            finishedOperationIDs.remove(operation.id)
            artifacts = Array(result.artifacts.prefix(TerminalArtifactLimits.maxScanItems))
            scanGeneration = result.generation
            state = .ready
        } catch is CancellationError {
            return
        } catch TerminalArtifactStoreError.staleIdentity {
            return
        } catch let error as CmuxRemoteRPCError {
            guard isCurrent(newIdentity, epoch: epoch) else { return }
            scanOperation = nil
            finishedOperationIDs.remove(operation.id)
            if case .rpc(let code, _) = error, code == RemoteErrorCode.methodNotFound.rawValue {
                state = .unavailable
            } else {
                state = .failed(String(describing: error))
            }
        } catch {
            guard isCurrent(newIdentity, epoch: epoch) else { return }
            scanOperation = nil
            finishedOperationIDs.remove(operation.id)
            state = .failed(String(describing: error))
        }
    }

    func thumbnail(for artifact: TerminalArtifact, dimension: Int = TerminalArtifactLimits.defaultThumbnailDimension) async throws -> Data {
        guard artifact.isImage else { throw TerminalArtifactStoreError.notAnImage }
        guard (64...TerminalArtifactLimits.maxThumbnailDimension).contains(dimension) else {
            throw TerminalArtifactStoreError.malformedThumbnail
        }
        let context = try activeContext(for: artifact)
        let key = TerminalArtifactThumbnailCacheKey(
            hostID: context.identity.hostID,
            accountScope: context.identity.accountScope,
            pathToken: artifact.artifactId,
            revision: artifact.revision,
            dimension: dimension
        )
        if let cached = await cache.thumbnail(for: key) {
            guard isCurrent(context.identity, epoch: context.epoch) else {
                throw TerminalArtifactStoreError.staleIdentity
            }
            return cached
        }

        let waiter = UUID()
        let operation: TerminalArtifactSharedOperation<Data>
        if var existing = thumbnailTasks[key] {
            existing.waiters.insert(waiter)
            thumbnailTasks[key] = existing
            operation = existing
        } else {
            operation = makeThumbnailOperation(artifact: artifact, key: key, dimension: dimension, waiter: waiter)
            thumbnailTasks[key] = operation
        }
        return try await waitForThumbnail(operation, key: key, waiter: waiter, context: context)
    }

    func openViewer(for artifact: TerminalArtifact) async throws -> URL {
        guard artifact.isImage else { throw TerminalArtifactStoreError.notAnImage }
        guard artifact.bytes <= TerminalArtifactLimits.maxImageBytes else { throw TerminalArtifactStoreError.imageTooLarge }
        let context = try activeContext(for: artifact)
        let expectedViewerEpoch = viewerEpoch
        let key = TerminalArtifactCacheKey(
            hostID: context.identity.hostID,
            accountScope: context.identity.accountScope,
            pathToken: artifact.artifactId,
            revision: artifact.revision
        )

        let fullWaiter = UUID()
        let fullOperation: TerminalArtifactSharedOperation<TerminalArtifactCacheKey>
        if var existing = fullTasks[key] {
            existing.waiters.insert(fullWaiter)
            fullTasks[key] = existing
            fullOperation = existing
        } else {
            fullOperation = makeFullOperation(artifact: artifact, key: key, waiter: fullWaiter)
            fullTasks[key] = fullOperation
        }
        _ = try await waitForFull(fullOperation, key: key, waiter: fullWaiter, context: context)
        guard isCurrent(context.identity, epoch: context.epoch), viewerEpoch == expectedViewerEpoch else {
            throw TerminalArtifactStoreError.staleIdentity
        }

        let viewerWaiter = UUID()
        let viewerOperation: TerminalArtifactSharedOperation<URL>
        if var existing = viewerTasks[key] {
            existing.waiters.insert(viewerWaiter)
            viewerTasks[key] = existing
            viewerOperation = existing
        } else {
            viewerOperation = makeViewerOperation(key: key, waiter: viewerWaiter)
            viewerTasks[key] = viewerOperation
        }
        let url = try await waitForViewer(
            viewerOperation,
            key: key,
            waiter: viewerWaiter,
            context: context,
            viewerEpoch: expectedViewerEpoch
        )
        if let oldViewerURL = viewerURL, oldViewerURL != url {
            await cache.removeViewerURL(oldViewerURL)
            guard isCurrent(context.identity, epoch: context.epoch), viewerEpoch == expectedViewerEpoch else {
                await cache.removeViewerURL(url)
                throw TerminalArtifactStoreError.staleIdentity
            }
        }
        viewerURL = url
        selection = artifact.artifactId
        return url
    }

    func dismissViewer() async {
        viewerEpoch &+= 1
        let url = viewerURL
        viewerURL = nil
        selection = nil
        await retireViewerWork()
        if let url { await cache.removeViewerURL(url) }
    }

    func resetForHostOrAccountChange() async {
        await activate(identity: nil)
        await cache.purgeAll()
    }

    var retiredOperationCount: Int { retiredOperations.count }

    func waitForRetiredOperationsToDrain() async {
        if retiredOperations.isEmpty { return }
        await withCheckedContinuation { retiredDrainWaiters.append($0) }
    }

    private func makeScanOperation(
        identity: TerminalArtifactIdentity,
        epoch: UInt64,
        waiter: UUID
    ) -> TerminalArtifactSharedOperation<TerminalArtifactScanResult> {
        let id = UUID()
        let completion = TerminalArtifactOperationCompletion<TerminalArtifactScanResult>()
        let rpc = rpc
        let cache = cache
        let task = Task { [weak self] in
            let result: Result<TerminalArtifactScanResult, any Error>
            do {
                try await cache.beginOperation(id)
                let response = try await rpc.call(
                    method: RemoteRPCMethod.artifactScan.rawValue,
                    params: .object([
                        "workspace_id": .string(identity.workspaceID),
                        "surface_id": .string(identity.surfaceID),
                    ])
                )
                try Task.checkCancellation()
                let scan = try response.unwrapResult().decode(TerminalArtifactScanResult.self)
                for artifact in scan.artifacts {
                    try await cache.invalidateRevisions(
                        hostID: identity.hostID,
                        accountScope: identity.accountScope,
                        pathToken: artifact.artifactId,
                        keeping: artifact.revision,
                        operationID: id
                    )
                }
                result = .success(scan)
            } catch {
                result = .failure(error)
            }
            await self?.operationRunnerFinished(id)
            await completion.finish(result)
        }
        return TerminalArtifactSharedOperation(id: id, kind: .scan, task: task, completion: completion, waiters: [waiter])
    }

    private func makeThumbnailOperation(
        artifact: TerminalArtifact,
        key: TerminalArtifactThumbnailCacheKey,
        dimension: Int,
        waiter: UUID
    ) -> TerminalArtifactSharedOperation<Data> {
        let id = UUID()
        let completion = TerminalArtifactOperationCompletion<Data>()
        let rpc = rpc
        let cache = cache
        let task = Task { [weak self] in
            let result: Result<Data, any Error>
            do {
                try await cache.beginOperation(id)
                let response = try await rpc.call(
                    method: RemoteRPCMethod.artifactThumbnail.rawValue,
                    params: .object([
                        "artifact_id": .string(artifact.artifactId),
                        "dimension": .int(Int64(dimension)),
                    ])
                )
                try Task.checkCancellation()
                let thumbnail: TerminalArtifactThumbnailResult
                do {
                    thumbnail = try response.unwrapResult().decode(TerminalArtifactThumbnailResult.self)
                } catch let error as CmuxRemoteRPCError {
                    throw error
                } catch {
                    throw TerminalArtifactStoreError.malformedThumbnail
                }
                guard thumbnail.artifactId == artifact.artifactId,
                      thumbnail.revision == artifact.revision,
                      thumbnail.dimension == dimension,
                      thumbnail.width <= dimension,
                      thumbnail.height <= dimension
                else { throw TerminalArtifactStoreError.malformedThumbnail }
                let data: Data
                do { data = try thumbnail.decodedBytes() } catch { throw TerminalArtifactStoreError.malformedThumbnail }
                try await cache.storeThumbnail(data, for: key, operationID: id)
                try Task.checkCancellation()
                result = .success(data)
            } catch {
                result = .failure(error)
            }
            await self?.operationRunnerFinished(id)
            await completion.finish(result)
        }
        return TerminalArtifactSharedOperation(id: id, kind: .thumbnail, task: task, completion: completion, waiters: [waiter])
    }

    private func makeFullOperation(
        artifact: TerminalArtifact,
        key: TerminalArtifactCacheKey,
        waiter: UUID
    ) -> TerminalArtifactSharedOperation<TerminalArtifactCacheKey> {
        let id = UUID()
        let completion = TerminalArtifactOperationCompletion<TerminalArtifactCacheKey>()
        let rpc = rpc
        let cache = cache
        let imageInspector = imageInspector
        let task = Task { [weak self] in
            let result: Result<TerminalArtifactCacheKey, any Error>
            do {
                try await cache.beginOperation(id)
                if await cache.containsFullContent(for: key) {
                    result = .success(key)
                } else {
                    let statResponse = try await rpc.call(
                        method: RemoteRPCMethod.artifactStat.rawValue,
                        params: .object(["artifact_id": .string(artifact.artifactId)])
                    )
                    try Task.checkCancellation()
                    let stat = try statResponse.unwrapResult().decode(TerminalArtifactStatResult.self)
                    guard stat.artifactId == artifact.artifactId,
                          stat.revision == artifact.revision,
                          stat.bytes == artifact.bytes
                    else { throw TerminalArtifactStoreError.artifactChanged }
                    guard stat.bytes <= TerminalArtifactLimits.maxImageBytes else { throw TerminalArtifactStoreError.imageTooLarge }
                    if let width = stat.width, let height = stat.height {
                        try Self.validatePixelCount(width: width, height: height)
                    }
                    let write = try await cache.beginFullWrite(for: key, operationID: id)
                    do {
                        var requestedOffset = 0
                        while true {
                            try Task.checkCancellation()
                            let response = try await rpc.call(
                                method: RemoteRPCMethod.artifactFetch.rawValue,
                                params: .object([
                                    "artifact_id": .string(artifact.artifactId),
                                    "offset": .int(Int64(requestedOffset)),
                                ])
                            )
                            try Task.checkCancellation()
                            let chunk: TerminalArtifactFetchResult
                            do {
                                chunk = try response.unwrapResult().decode(TerminalArtifactFetchResult.self)
                            } catch let error as CmuxRemoteRPCError {
                                throw error
                            } catch {
                                throw TerminalArtifactStoreError.malformedChunk
                            }
                            let data: Data
                            do { data = try chunk.decodedBytes() } catch { throw TerminalArtifactStoreError.malformedChunk }
                            guard chunk.artifactId == artifact.artifactId,
                                  chunk.offset == requestedOffset,
                                  chunk.totalBytes == stat.bytes,
                                  chunk.revision == stat.revision,
                                  chunk.eof || !data.isEmpty
                            else { throw TerminalArtifactStoreError.malformedChunk }
                            let nextOffset = requestedOffset + data.count
                            guard nextOffset <= stat.bytes, chunk.eof == (nextOffset == stat.bytes) else {
                                throw TerminalArtifactStoreError.malformedChunk
                            }
                            try await cache.append(data, to: write)
                            requestedOffset = nextOffset
                            if chunk.eof { break }
                        }
                        guard let partialURL = await cache.partialFileURL(for: write) else {
                            throw TerminalArtifactStoreError.malformedChunk
                        }
                        let dimensions = try imageInspector.dimensions(of: partialURL)
                        try Self.validatePixelCount(width: dimensions.width, height: dimensions.height)
                        try await cache.commitFullWrite(write, expectedBytes: stat.bytes)
                        try Task.checkCancellation()
                        result = .success(key)
                    } catch {
                        await cache.abortFullWrite(write)
                        throw error
                    }
                }
            } catch {
                result = .failure(error)
            }
            await self?.operationRunnerFinished(id)
            await completion.finish(result)
        }
        return TerminalArtifactSharedOperation(id: id, kind: .full, task: task, completion: completion, waiters: [waiter])
    }

    private func makeViewerOperation(
        key: TerminalArtifactCacheKey,
        waiter: UUID
    ) -> TerminalArtifactSharedOperation<URL> {
        let id = UUID()
        let completion = TerminalArtifactOperationCompletion<URL>()
        let cache = cache
        let task = Task { [weak self] in
            let result: Result<URL, any Error>
            do {
                try await cache.beginOperation(id)
                guard let url = try await cache.makeViewerURL(for: key, operationID: id) else {
                    throw TerminalArtifactStoreError.malformedChunk
                }
                result = .success(url)
            } catch {
                result = .failure(error)
            }
            await self?.operationRunnerFinished(id)
            await completion.finish(result)
        }
        return TerminalArtifactSharedOperation(id: id, kind: .viewer, task: task, completion: completion, waiters: [waiter])
    }

    private func waitForScan(
        _ operation: TerminalArtifactSharedOperation<TerminalArtifactScanResult>,
        waiter: UUID
    ) async throws -> TerminalArtifactScanResult {
        try await withTaskCancellationHandler {
            try await operation.completion.value(waiter: waiter)
        } onCancel: {
            Task { @MainActor [weak self] in
                await operation.completion.cancel(waiter: waiter)
                await self?.releaseScan(operationID: operation.id, waiter: waiter)
            }
        }
    }

    private func waitForThumbnail(
        _ operation: TerminalArtifactSharedOperation<Data>,
        key: TerminalArtifactThumbnailCacheKey,
        waiter: UUID,
        context: (identity: TerminalArtifactIdentity, epoch: UInt64)
    ) async throws -> Data {
        do {
            let data = try await withTaskCancellationHandler {
                try await operation.completion.value(waiter: waiter)
            } onCancel: {
                Task { @MainActor [weak self] in
                    await operation.completion.cancel(waiter: waiter)
                    await self?.releaseThumbnail(key: key, waiter: waiter)
                }
            }
            await releaseThumbnail(key: key, waiter: waiter)
            guard isCurrent(context.identity, epoch: context.epoch) else {
                throw TerminalArtifactStoreError.staleIdentity
            }
            return data
        } catch {
            await releaseThumbnail(key: key, waiter: waiter)
            throw error
        }
    }

    private func waitForFull(
        _ operation: TerminalArtifactSharedOperation<TerminalArtifactCacheKey>,
        key: TerminalArtifactCacheKey,
        waiter: UUID,
        context: (identity: TerminalArtifactIdentity, epoch: UInt64)
    ) async throws -> TerminalArtifactCacheKey {
        do {
            let value = try await withTaskCancellationHandler {
                try await operation.completion.value(waiter: waiter)
            } onCancel: {
                Task { @MainActor [weak self] in
                    await operation.completion.cancel(waiter: waiter)
                    await self?.releaseFull(key: key, waiter: waiter)
                }
            }
            await releaseFull(key: key, waiter: waiter)
            guard isCurrent(context.identity, epoch: context.epoch) else {
                throw TerminalArtifactStoreError.staleIdentity
            }
            return value
        } catch {
            await releaseFull(key: key, waiter: waiter)
            throw error
        }
    }

    private func waitForViewer(
        _ operation: TerminalArtifactSharedOperation<URL>,
        key: TerminalArtifactCacheKey,
        waiter: UUID,
        context: (identity: TerminalArtifactIdentity, epoch: UInt64),
        viewerEpoch expectedViewerEpoch: UInt64
    ) async throws -> URL {
        do {
            let url = try await withTaskCancellationHandler {
                try await operation.completion.value(waiter: waiter)
            } onCancel: {
                Task { @MainActor [weak self] in
                    await operation.completion.cancel(waiter: waiter)
                    await self?.releaseViewer(key: key, waiter: waiter)
                }
            }
            await releaseViewer(key: key, waiter: waiter)
            guard isCurrent(context.identity, epoch: context.epoch), viewerEpoch == expectedViewerEpoch else {
                await cache.removeViewerURL(url)
                throw TerminalArtifactStoreError.staleIdentity
            }
            return url
        } catch {
            await releaseViewer(key: key, waiter: waiter)
            throw error
        }
    }

    private func releaseScan(operationID: UUID, waiter: UUID) async {
        guard var operation = scanOperation, operation.id == operationID, operation.waiters.remove(waiter) != nil else { return }
        if operation.waiters.isEmpty {
            scanOperation = nil
            await retire(operation)
        } else {
            scanOperation = operation
        }
    }

    private func releaseThumbnail(key: TerminalArtifactThumbnailCacheKey, waiter: UUID) async {
        guard var operation = thumbnailTasks[key], operation.waiters.remove(waiter) != nil else { return }
        if operation.waiters.isEmpty {
            thumbnailTasks[key] = nil
            await retire(operation)
        } else {
            thumbnailTasks[key] = operation
        }
    }

    private func releaseFull(key: TerminalArtifactCacheKey, waiter: UUID) async {
        guard var operation = fullTasks[key], operation.waiters.remove(waiter) != nil else { return }
        if operation.waiters.isEmpty {
            fullTasks[key] = nil
            await retire(operation)
        } else {
            fullTasks[key] = operation
        }
    }

    private func releaseViewer(key: TerminalArtifactCacheKey, waiter: UUID) async {
        guard var operation = viewerTasks[key], operation.waiters.remove(waiter) != nil else { return }
        if operation.waiters.isEmpty {
            viewerTasks[key] = nil
            await retire(operation)
        } else {
            viewerTasks[key] = operation
        }
    }

    private func retire<Value>(_ operation: TerminalArtifactSharedOperation<Value>) async {
        if finishedOperationIDs.remove(operation.id) != nil { return }
        await operation.completion.retire()
        operation.task.cancel()
        await cache.retireOperation(operation.id)
        retiredOperations[operation.id] = TerminalArtifactRetiredOperation(
            id: operation.id,
            kind: operation.kind,
            task: operation.task
        )
    }

    private func retireAllOperations() async {
        let scan = scanOperation
        let thumbnails = Array(thumbnailTasks.values)
        let full = Array(fullTasks.values)
        let viewers = Array(viewerTasks.values)
        scanOperation = nil
        thumbnailTasks.removeAll()
        fullTasks.removeAll()
        viewerTasks.removeAll()
        if let scan { await retire(scan) }
        for operation in thumbnails { await retire(operation) }
        for operation in full { await retire(operation) }
        for operation in viewers { await retire(operation) }
    }

    private func retireViewerWork() async {
        let full = Array(fullTasks.values)
        let viewers = Array(viewerTasks.values)
        fullTasks.removeAll()
        viewerTasks.removeAll()
        for operation in full { await retire(operation) }
        for operation in viewers { await retire(operation) }
    }

    private func operationRunnerFinished(_ operationID: UUID) async {
        await cache.finishOperation(operationID)
        if retiredOperations.removeValue(forKey: operationID) != nil {
            if retiredOperations.isEmpty {
                let waiters = retiredDrainWaiters
                retiredDrainWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        } else {
            finishedOperationIDs.insert(operationID)
        }
    }

    private func activeContext(for artifact: TerminalArtifact) throws -> (identity: TerminalArtifactIdentity, epoch: UInt64) {
        guard let identity else { throw TerminalArtifactStoreError.inactive }
        guard artifacts.contains(where: { $0.artifactId == artifact.artifactId && $0.revision == artifact.revision }) else {
            throw TerminalArtifactStoreError.artifactChanged
        }
        return (identity, identityEpoch)
    }

    private func isCurrent(_ expectedIdentity: TerminalArtifactIdentity, epoch: UInt64) -> Bool {
        identity == expectedIdentity && identityEpoch == epoch
    }

    private static func validatePixelCount(width: Int, height: Int) throws {
        guard width > 0,
              height > 0,
              width <= TerminalArtifactLimits.maxImagePixels / height
        else { throw TerminalArtifactStoreError.tooManyPixels }
        guard width * height <= TerminalArtifactLimits.maxImagePixels else {
            throw TerminalArtifactStoreError.tooManyPixels
        }
    }
}
