import Foundation
import SharedKit
import Testing
@testable import CmuxRemote

@Suite("FeatureCompositionTests", .serialized, .timeLimit(.minutes(1)))
struct FeatureCompositionTests {
    @Test
    func demoRelayServesExactFileFeatureContracts() async throws {
        let rpc = DemoRPCDispatch(fileFeatureFixturesEnabled: true)

        let capabilities = try await rpc.call(
            method: RemoteRPCMethod.hostCapabilities.rawValue,
            params: .object([:])
        ).decodeResult(HostCapabilitiesResult.self)
        #expect(capabilities.capabilities == [
            HostCapabilities.chunkUploadV2,
            HostCapabilities.terminalArtifactsV1,
        ])

        let batchID = "00000000-0000-4000-8000-000000000008"
        let bytes = Data([0x63, 0x6d, 0x75, 0x78])
        let begin = try await rpc.call(
            method: RemoteRPCMethod.uploadBegin.rawValue,
            params: try Self.params(ChunkUploadBeginRequest(
                batchId: batchID,
                filename: "fixture.zip",
                mimeType: "application/zip",
                bytes: bytes.count,
                sha256: String(repeating: "a", count: 64),
                batchFileCount: 1,
                batchBytes: bytes.count
            ))
        ).decodeResult(ChunkUploadBeginResult.self)
        #expect(begin == ChunkUploadBeginResult(
            uploadId: "demo-upload-0001",
            batchId: batchID,
            chunkBytes: ChunkUploadLimits.rawChunkBytes
        ))

        let progress = try await rpc.call(
            method: RemoteRPCMethod.uploadChunk.rawValue,
            params: try Self.params(ChunkUploadChunkRequest(
                uploadId: begin.uploadId,
                offset: 0,
                dataBase64: bytes.base64EncodedString()
            ))
        ).decodeResult(ChunkUploadChunkResult.self)
        #expect(progress == ChunkUploadChunkResult(
            uploadId: begin.uploadId,
            nextOffset: bytes.count,
            receivedBytes: bytes.count
        ))

        let committed = try await rpc.call(
            method: RemoteRPCMethod.uploadCommit.rawValue,
            params: try Self.params(ChunkUploadCommitRequest(uploadId: begin.uploadId))
        ).decodeResult(ChunkUploadCommitResult.self)
        #expect(committed == ChunkUploadCommitResult(
            uploadId: begin.uploadId,
            filename: "fixture.zip",
            path: "/Users/demo/Drop/0-it's fixture.zip",
            bytes: bytes.count,
            mimeType: "application/zip",
            sha256: String(repeating: "a", count: 64)
        ))

        let secondBegin = try await rpc.call(
            method: RemoteRPCMethod.uploadBegin.rawValue,
            params: try Self.params(ChunkUploadBeginRequest(
                batchId: batchID,
                filename: "cancel.pdf",
                mimeType: "application/pdf",
                bytes: 1,
                sha256: String(repeating: "b", count: 64),
                batchFileCount: 1,
                batchBytes: 1
            ))
        ).decodeResult(ChunkUploadBeginResult.self)
        let cancelled = try await rpc.call(
            method: RemoteRPCMethod.uploadCancel.rawValue,
            params: try Self.params(ChunkUploadCancelRequest(uploadId: secondBegin.uploadId))
        ).decodeResult(ChunkUploadCancelResult.self)
        #expect(cancelled == ChunkUploadCancelResult(uploadId: secondBegin.uploadId, cancelled: true))
    }

    @Test
    func demoRelayServesArtifactSuccessStaleUnavailableErrorAndMalformedStates() async throws {
        let rpc = DemoRPCDispatch(fileFeatureFixturesEnabled: true)
        let scan = try await rpc.call(
            method: RemoteRPCMethod.artifactScan.rawValue,
            params: try Self.params(TerminalArtifactScanRequest(
                workspaceId: "WS-DEMO-1",
                surfaceId: DemoContent.fileFeatureHappySurfaceID
            ))
        ).decodeResult(TerminalArtifactScanResult.self)
        #expect(scan.generation == DemoContent.fileFeatureScanGeneration)
        #expect(scan.artifacts == [DemoContent.fileFeatureImageArtifact, DemoContent.fileFeatureDocumentArtifact])

        let stat = try await rpc.call(
            method: RemoteRPCMethod.artifactStat.rawValue,
            params: try Self.params(TerminalArtifactStatRequest(
                artifactId: DemoContent.fileFeatureImageArtifact.artifactId
            ))
        ).decodeResult(TerminalArtifactStatResult.self)
        #expect(stat.revision == DemoContent.fileFeatureImageArtifact.revision)
        #expect(stat.width == DemoContent.fileFeatureImageWidth)
        #expect(stat.height == DemoContent.fileFeatureImageHeight)

        let thumbnail = try await rpc.call(
            method: RemoteRPCMethod.artifactThumbnail.rawValue,
            params: try Self.params(TerminalArtifactThumbnailRequest(
                artifactId: DemoContent.fileFeatureImageArtifact.artifactId,
                dimension: TerminalArtifactLimits.defaultThumbnailDimension
            ))
        ).decodeResult(TerminalArtifactThumbnailResult.self)
        #expect(thumbnail.width == DemoContent.fileFeatureImageWidth)
        #expect(thumbnail.height == DemoContent.fileFeatureImageHeight)
        #expect(try thumbnail.decodedBytes() == DemoContent.fileFeatureThumbnailBytes)

        let fetched = try await rpc.call(
            method: RemoteRPCMethod.artifactFetch.rawValue,
            params: try Self.params(TerminalArtifactFetchRequest(
                artifactId: DemoContent.fileFeatureImageArtifact.artifactId,
                offset: 0
            ))
        ).decodeResult(TerminalArtifactFetchResult.self)
        #expect(fetched.eof)
        #expect(try fetched.decodedBytes() == DemoContent.fileFeatureImageBytes)

        let stale = try await rpc.call(
            method: RemoteRPCMethod.artifactStat.rawValue,
            params: try Self.params(TerminalArtifactStatRequest(artifactId: DemoContent.fileFeatureStaleArtifactID))
        )
        #expect(stale.error?.code == RemoteErrorCode.fileChanged.rawValue)

        let unavailable = try await rpc.call(
            method: RemoteRPCMethod.artifactScan.rawValue,
            params: try Self.params(TerminalArtifactScanRequest(
                workspaceId: "WS-DEMO-1",
                surfaceId: DemoContent.fileFeatureUnavailableSurfaceID
            ))
        )
        #expect(unavailable.error?.code == RemoteErrorCode.methodNotFound.rawValue)

        let failed = try await rpc.call(
            method: RemoteRPCMethod.artifactScan.rawValue,
            params: try Self.params(TerminalArtifactScanRequest(
                workspaceId: "WS-DEMO-1",
                surfaceId: DemoContent.fileFeatureErrorSurfaceID
            ))
        )
        #expect(failed.error?.code == RemoteErrorCode.forbidden.rawValue)

        let malformed = try await rpc.call(
            method: RemoteRPCMethod.artifactScan.rawValue,
            params: try Self.params(TerminalArtifactScanRequest(
                workspaceId: "WS-DEMO-1",
                surfaceId: DemoContent.fileFeatureMalformedSurfaceID
            ))
        )
        #expect(throws: (any Error).self) {
            _ = try malformed.decodeResult(TerminalArtifactScanResult.self)
        }
    }

    @Test @MainActor
    func coordinatorComposesCapabilitiesAndArtifactIdentityThenDeactivates() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-coordinator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let routingRPC = OfflineRPCDispatch()
        let attachmentStore = AttachmentStore(rpc: routingRPC)
        let attachmentCoordinator = AttachmentCoordinator(
            store: attachmentStore,
            photoStager: TestAttachmentPhotoStager()
        )
        let artifactStore = TerminalArtifactStore(
            rpc: routingRPC,
            cache: TerminalArtifactCache(rootURL: cacheRoot)
        )
        let coordinator = RemoteFileFeatureCoordinator(
            routingRPC: routingRPC,
            attachments: attachmentCoordinator,
            terminalArtifacts: artifactStore
        )
        let rpc = DemoRPCDispatch(fileFeatureFixturesEnabled: true)

        await coordinator.connect(rpc: rpc, hostID: "demo-host", accountScope: "demo-account")

        #expect(coordinator.hostGeneration == 1)
        #expect(coordinator.hostID == "demo-host")
        #expect(coordinator.accountScope == "demo-account")
        #expect(coordinator.capabilities.supportsChunkUploadV2)
        #expect(coordinator.capabilities.supportsTerminalArtifactsV1)
        #expect(attachmentStore.hostGeneration == 1)

        await coordinator.activateArtifacts(
            isConnected: true,
            workspaceID: "WS-DEMO-1",
            surfaceID: DemoContent.fileFeatureHappySurfaceID
        )
        #expect(artifactStore.identity == TerminalArtifactIdentity(
            hostID: "demo-host",
            accountScope: "demo-account",
            hostGeneration: 1,
            workspaceID: "WS-DEMO-1",
            surfaceID: DemoContent.fileFeatureHappySurfaceID
        ))

        await coordinator.deactivate(purgeAccountCache: false)

        #expect(coordinator.hostGeneration == 2)
        #expect(coordinator.hostID == "offline")
        #expect(coordinator.accountScope == "offline")
        #expect(coordinator.capabilities.capabilities.isEmpty)
        #expect(attachmentStore.hostGeneration == 2)
        #expect(artifactStore.identity == nil)
    }

    @Test @MainActor
    func attachmentCoordinatorReplacesTrackedPathsWithoutLosingUserEdits() throws {
        let coordinator = AttachmentCoordinator(
            store: AttachmentStore(rpc: OfflineRPCDispatch()),
            photoStager: TestAttachmentPhotoStager()
        )

        let first = coordinator.mergedDraft(
            currentDraft: "echo",
            quotedPaths: ["'/tmp/a file.pdf'"]
        )
        #expect(first == "echo '/tmp/a file.pdf'")

        let retried = coordinator.mergedDraft(
            currentDraft: "echo '/tmp/a file.pdf' --verbose",
            quotedPaths: ["'/tmp/a file.pdf'", "'/tmp/b.zip'"]
        )
        #expect(retried == "echo '/tmp/a file.pdf' '/tmp/b.zip' --verbose")
        #expect(coordinator.mergedDraft(
            currentDraft: try #require(retried),
            quotedPaths: ["'/tmp/a file.pdf'", "'/tmp/b.zip'"]
        ) == nil)
    }

    @Test @MainActor
    func hostSurfaceSwitchIgnoresGatedStaleFeatureResponseWithoutChangingTerminalState() async throws {
        let rpc = DemoRPCDispatch(
            fileFeatureFixturesEnabled: true,
            staleFeatureResponseGateEnabled: true
        )
        let stateSignal = AsyncStream.makeStream(of: String.self)
        await rpc.setOnFileFeatureQAState { state in
            stateSignal.continuation.yield(state)
        }
        var states = stateSignal.stream.makeAsyncIterator()
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-composition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let artifactStore = TerminalArtifactStore(
            rpc: rpc,
            cache: TerminalArtifactCache(rootURL: cacheRoot)
        )
        let terminalStore = SurfaceStore(rpc: rpc)
        terminalStore.grid.replaceRow(0, raw: "terminal invariant")
        terminalStore.rev = 17
        terminalStore.inputStatus = .sent("input invariant")

        let oldActivation = Task {
            await artifactStore.activate(identity: TerminalArtifactIdentity(
                hostID: "demo-host",
                accountScope: "demo-account",
                hostGeneration: 1,
                workspaceID: "WS-DEMO-1",
                surfaceID: DemoContent.fileFeatureHappySurfaceID
            ))
        }
        #expect(await states.next() == DemoContent.fileFeatureQAStateBlocked)

        await artifactStore.activate(identity: TerminalArtifactIdentity(
            hostID: "demo-host",
            accountScope: "demo-account",
            hostGeneration: 2,
            workspaceID: "WS-DEMO-1",
            surfaceID: DemoContent.fileFeatureReplacementSurfaceID
        ))
        let expectedArtifacts = artifactStore.artifacts
        await rpc.releaseStaleFileFeatureResponse()
        #expect(await states.next() == DemoContent.fileFeatureQAStateReleased)
        await oldActivation.value

        #expect(artifactStore.identity?.hostGeneration == 2)
        #expect(artifactStore.identity?.surfaceID == DemoContent.fileFeatureReplacementSurfaceID)
        #expect(artifactStore.artifacts == expectedArtifacts)
        #expect(artifactStore.artifacts.first?.revision == DemoContent.fileFeatureReplacementRevision)
        #expect(terminalStore.grid.rawRows[0] == "terminal invariant")
        #expect(terminalStore.rev == 17)
        #expect(terminalStore.inputStatus == .sent("input invariant"))
        #expect(terminalStore.subscribed == nil)
    }

    private static func params<Value: Encodable>(_ value: Value) throws -> JSONValue {
        let data = try SharedKitJSON.snakeCaseEncoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

private actor TestAttachmentPhotoStager: AttachmentPhotoStaging {
    func stage(_ data: Data) async throws -> AttachmentSelection {
        AttachmentSelection(url: URL(fileURLWithPath: "/tmp/test-photo.jpg"), declaredMIMEType: "image/jpeg")
    }

    func remove(_ selection: AttachmentSelection) async {}
}
