import Foundation
import Observation
import SharedKit

@MainActor
@Observable
final class SurfaceDocumentStore {
    private(set) var surfaceID: String?
    private(set) var state: SurfaceDocumentState = .idle
    private(set) var isRefreshing = false

    private let rpc: any RPCDispatch
    private var epoch: UInt64 = 0

    init(rpc: any RPCDispatch) {
        self.rpc = rpc
    }

    func open(workspaceID: String, surfaceID: String, isConnected: Bool) async {
        epoch &+= 1
        let expectedEpoch = epoch
        let isSameSurface = self.surfaceID == surfaceID
        self.surfaceID = surfaceID
        guard isConnected else {
            isRefreshing = false
            state = .failed(.disconnected)
            return
        }
        if isSameSurface, case .loaded = state {
            isRefreshing = true
        } else {
            state = .loading
        }

        let outcome: SurfaceDocumentState
        do {
            let response = try await rpc.call(
                method: RemoteRPCMethod.surfaceDocumentOpen.rawValue,
                params: .object([
                    "workspace_id": .string(workspaceID),
                    "surface_id": .string(surfaceID),
                ])
            )
            try Task.checkCancellation()
            let scan: TerminalArtifactScanResult
            do {
                scan = try response.unwrapResult().decode(TerminalArtifactScanResult.self)
            } catch let error as CmuxRemoteRPCError {
                throw error
            } catch {
                throw TextArtifactLoaderError.malformedChunk
            }
            guard scan.artifacts.count == 1, let artifact = scan.artifacts.first else {
                throw TextArtifactLoaderError.malformedChunk
            }
            let document = try await TextArtifactLoader(rpc: rpc).load(artifact)
            try Task.checkCancellation()
            outcome = .loaded(await RenderedDocument.render(document, asMarkdown: true))
        } catch is CancellationError {
            guard expectedEpoch == epoch else { return }
            isRefreshing = false
            if case .loading = state { state = .idle }
            return
        } catch let CmuxRemoteRPCError.rpc(code, _) where code == RemoteErrorCode.methodNotFound.rawValue {
            outcome = .unsupported
        } catch {
            outcome = .failed(DocumentLoadFailure(error: error))
        }
        guard expectedEpoch == epoch else { return }
        isRefreshing = false
        state = outcome
    }

    func reset() {
        epoch &+= 1
        surfaceID = nil
        isRefreshing = false
        state = .idle
    }
}
