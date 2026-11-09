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
    let feed: FeedStore
    let transcripts: ClaudeTranscriptStore
    let relayVersion: RelayVersionStore

    private let routingRPC: OfflineRPCDispatch

    private(set) var capabilities = HostCapabilitiesResult(capabilities: [])
    /// `true` once this connection's `host.capabilities` answered (or failed), so an empty list
    /// means a relay without the capability rather than one still being asked.
    private(set) var capabilitiesResolved = false
    /// Survives disconnects so a document tab keeps its error screen instead of
    /// falling back to the card; only a capability answer or an account purge changes it.
    private(set) var documentRoutingEnabled = false
    /// Same lifetime as `documentRoutingEnabled`, for `surface.browser.v1`.
    private(set) var browserRoutingEnabled = false
    /// Same lifetime as `documentRoutingEnabled`, for `feed.v1`, so the Claude tab can show
    /// its disconnected state instead of vanishing while the relay reconnects.
    private(set) var feedRoutingEnabled = false
    /// Same lifetime as `documentRoutingEnabled`, for `claude.transcript.v1`.
    private(set) var transcriptRoutingEnabled = false
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
        self.feed = FeedStore(rpc: routingRPC)
        self.transcripts = ClaudeTranscriptStore(rpc: routingRPC)
        self.relayVersion = RelayVersionStore(rpc: routingRPC)
    }

    var feedEnabled: Bool { feedRoutingEnabled && !feed.isUnsupported }
    var transcriptEnabled: Bool { transcriptRoutingEnabled && !transcripts.isUnsupported }
    var agentsEnabled: Bool { feedEnabled || transcriptEnabled }

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
        capabilitiesResolved = false
        documents.reset()
        browsers.reset()
        feed.reset()
        transcripts.reset()
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
            capabilitiesResolved = true
            documentRoutingEnabled = nextCapabilities.supportsSurfaceDocumentV1
            browserRoutingEnabled = nextCapabilities.supportsSurfaceBrowserV1
            feedRoutingEnabled = nextCapabilities.supportsFeedV1
            transcriptRoutingEnabled = nextCapabilities.supportsClaudeTranscriptV1
        } catch {
            guard generation == hostGeneration else { return }
            capabilities = HostCapabilitiesResult(capabilities: [])
            capabilitiesResolved = true
            documentRoutingEnabled = false
            browserRoutingEnabled = false
            feedRoutingEnabled = false
            transcriptRoutingEnabled = false
        }
    }

    func deactivate(purgeAccountCache: Bool) async {
        hostGeneration &+= 1
        hostID = "offline"
        accountScope = "offline"
        capabilities = HostCapabilitiesResult(capabilities: [])
        capabilitiesResolved = false
        qaState = nil
        releaseStaleFixtureResponse = nil
        documents.reset()
        browsers.reset()
        feed.reset()
        transcripts.reset()
        if purgeAccountCache {
            relayVersion.reset()
            documentRoutingEnabled = false
            browserRoutingEnabled = false
            feedRoutingEnabled = false
            transcriptRoutingEnabled = false
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
