import Observation
import SharedKit

/// Coordinates remote-file capability, host, attachment, and artifact lifecycle state.
@MainActor
@Observable
final class RemoteFileFeatureCoordinator {
    let attachments: AttachmentCoordinator
    let terminalArtifacts: TerminalArtifactStore

    private let routingRPC: OfflineRPCDispatch

    private(set) var capabilities = HostCapabilitiesResult(capabilities: [])
    private(set) var hostGeneration = 0
    private(set) var hostID = "offline"
    private(set) var accountScope = "offline"
    private(set) var qaState: String?
    private(set) var releaseStaleFixtureResponse: (() -> Void)?

    init(
        routingRPC: OfflineRPCDispatch,
        attachments: AttachmentCoordinator,
        terminalArtifacts: TerminalArtifactStore
    ) {
        self.routingRPC = routingRPC
        self.attachments = attachments
        self.terminalArtifacts = terminalArtifacts
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
        } catch {
            guard generation == hostGeneration else { return }
            capabilities = HostCapabilitiesResult(capabilities: [])
        }
    }

    func deactivate(purgeAccountCache: Bool) async {
        hostGeneration &+= 1
        hostID = "offline"
        accountScope = "offline"
        capabilities = HostCapabilitiesResult(capabilities: [])
        qaState = nil
        releaseStaleFixtureResponse = nil
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
