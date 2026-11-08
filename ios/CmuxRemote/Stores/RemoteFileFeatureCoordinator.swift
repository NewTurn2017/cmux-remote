import Observation
import SharedKit

/// Coordinates remote-file capability, host, attachment, and artifact lifecycle state.
@MainActor
@Observable
final class RemoteFileFeatureCoordinator {
    let attachments: AttachmentCoordinator
    let terminalArtifacts: TerminalArtifactStore
    let documents: SurfaceDocumentStore
    let browsers: SurfaceBrowserStore

    private let routingRPC: OfflineRPCDispatch

    private(set) var capabilities = HostCapabilitiesResult(capabilities: [])
    /// Survives disconnects so a document tab keeps its error screen instead of
    /// falling back to the card; only a capability answer or an account purge changes it.
    private(set) var documentRoutingEnabled = false
    /// Same lifetime as `documentRoutingEnabled`, for `surface.browser.v1`.
    private(set) var browserRoutingEnabled = false
    private(set) var hostGeneration = 0
    private(set) var hostID = "offline"
    private(set) var accountScope = "offline"
    private(set) var qaState: String?
    private(set) var releaseStaleFixtureResponse: (() -> Void)?

    init(
        routingRPC: OfflineRPCDispatch,
        attachments: AttachmentCoordinator,
        terminalArtifacts: TerminalArtifactStore,
        browserRefreshSeconds: Double = BrowserRefreshPolicy.defaultIntervalSeconds
    ) {
        self.routingRPC = routingRPC
        self.attachments = attachments
        self.terminalArtifacts = terminalArtifacts
        self.documents = SurfaceDocumentStore(rpc: routingRPC)
        self.browsers = SurfaceBrowserStore(rpc: routingRPC, baseIntervalSeconds: browserRefreshSeconds)
    }

    func connect(
        rpc: any RPCDispatch,
        hostID: String,
        accountScope: String
    ) async {
        hostGeneration &+= 1
        let generation = hostGeneration
        self.hostID = hostID
        self.accountScope = accountScope
        capabilities = HostCapabilitiesResult(capabilities: [])
        documents.reset()
        browsers.reset()
        await routingRPC.install(rpc)
        await attachments.setHostGeneration(generation)
        await terminalArtifacts.activate(identity: nil)
        do {
            let response = try await rpc.call(
                method: RemoteRPCMethod.hostCapabilities.rawValue,
                params: .object([:])
            )
            let nextCapabilities = try response.decodeResult(HostCapabilitiesResult.self)
            guard generation == hostGeneration else { return }
            capabilities = nextCapabilities
            documentRoutingEnabled = nextCapabilities.supportsSurfaceDocumentV1
            browserRoutingEnabled = nextCapabilities.supportsSurfaceBrowserV1
        } catch {
            guard generation == hostGeneration else { return }
            capabilities = HostCapabilitiesResult(capabilities: [])
            documentRoutingEnabled = false
            browserRoutingEnabled = false
        }
    }

    func deactivate(purgeAccountCache: Bool) async {
        hostGeneration &+= 1
        hostID = "offline"
        accountScope = "offline"
        capabilities = HostCapabilitiesResult(capabilities: [])
        qaState = nil
        releaseStaleFixtureResponse = nil
        documents.reset()
        browsers.reset()
        if purgeAccountCache {
            documentRoutingEnabled = false
            browserRoutingEnabled = false
        }
        await routingRPC.removeTarget()
        await attachments.setHostGeneration(hostGeneration)
        if purgeAccountCache {
            await terminalArtifacts.resetForHostOrAccountChange()
        } else {
            await terminalArtifacts.activate(identity: nil)
        }
    }

    func activateArtifacts(
        isConnected: Bool,
        workspaceID: String?,
        surfaceID: String?
    ) async {
        guard capabilities.supportsTerminalArtifactsV1,
              isConnected,
              let workspaceID,
              let surfaceID
        else {
            await terminalArtifacts.activate(identity: nil)
            return
        }
        await terminalArtifacts.activate(identity: TerminalArtifactIdentity(
            hostID: hostID,
            accountScope: accountScope,
            hostGeneration: hostGeneration,
            workspaceID: workspaceID,
            surfaceID: surfaceID
        ))
    }

    func configureFixtureQA(state: String?, release: (() -> Void)?) {
        qaState = state
        releaseStaleFixtureResponse = release
    }

    func setQAState(_ state: String?) {
        qaState = state
    }
}
