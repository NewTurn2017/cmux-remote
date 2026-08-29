import SwiftUI

/// Stable composition seam for terminal-artifact controls and deterministic fixture state.
struct TerminalArtifactControlSlot: View {
    @Bindable var remoteFiles: RemoteFileFeatureCoordinator
    @Bindable var surfaceStore: SurfaceStore
    let connection: ConnectionState
    let workspaceID: String?
    let surfaceID: String?

    @State private var isPresentingFiles = false
    @State private var sheetDetent: PresentationDetent = .medium

    private var store: TerminalArtifactStore {
        remoteFiles.terminalArtifacts
    }

    private var isEnabled: Bool {
        remoteFiles.capabilities.supportsTerminalArtifactsV1
    }

    private var qaState: String? {
        remoteFiles.qaState
    }

    private var releaseStaleFixtureResponse: (() -> Void)? {
        remoteFiles.releaseStaleFixtureResponse
    }

    private var usesPopover: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        ZStack {
            filesButton

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("TerminalArtifactFeatureControlSlot")
                .accessibilityValue(featureState)
                .allowsHitTesting(false)

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("TerminalArtifactViewerTempCount")
                .accessibilityLabel(String(
                    localized: "terminal.artifact.viewer.temp_files",
                    defaultValue: "Temporary viewer files"
                ))
                .accessibilityValue(store.viewerURL == nil ? "0" : "1")
                .allowsHitTesting(false)

            if let qaState {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("FileFeatureContinuationGateState")
                    .accessibilityValue(qaState)
                    .allowsHitTesting(false)

                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("FeatureTerminalInvariantState")
                    .accessibilityValue(terminalInvariant)
                    .allowsHitTesting(false)
            }

            #if DEBUG
            if let releaseStaleFixtureResponse,
               !isPresentingFiles,
               qaState == "blocked" || qaState == "thumbnail-blocked"
            {
                Button(action: releaseStaleFixtureResponse) {
                    Color.clear
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("FeatureFixtureReleaseStaleResponse")
            }
            #endif
        }
        .frame(width: 44, height: 44)
        .overlay(alignment: .topTrailing) {
            #if DEBUG
            if usesConstrainedWidthHarness, isPresentingFiles {
                TerminalFilesSheet(
                    store: store,
                    onClose: dismissFiles,
                    fixtureReleaseAction: presentedFixtureReleaseAction
                )
                    .frame(width: 480, height: 560)
                    .background(CmuxTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                    }
                    .shadow(color: CmuxTheme.hardShadow, radius: 24, x: 0, y: 12)
                    .offset(y: 52)
            }
            #endif
        }
        .zIndex(isPresentingFiles ? 100 : 0)
        .task(id: activationID) {
            await activate()
        }
        .sheet(isPresented: phonePresentation) {
            TerminalFilesSheet(
                store: store,
                onClose: dismissFiles,
                fixtureReleaseAction: presentedFixtureReleaseAction
            )
                .presentationDetents([.medium, .large], selection: $sheetDetent)
                .presentationDragIndicator(.visible)
                .presentationBackground(CmuxTheme.surface)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .popover(isPresented: padPresentation, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            TerminalFilesSheet(
                store: store,
                onClose: dismissFiles,
                fixtureReleaseAction: presentedFixtureReleaseAction
            )
                .frame(idealWidth: 480, maxWidth: 520, idealHeight: 560, maxHeight: 620)
                .presentationCompactAdaptation(.none)
                .presentationBackground(CmuxTheme.surface)
        }
    }

    private var filesButton: some View {
        Button(action: presentFiles) {
            Image(systemName: "photo.stack")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(canPresent ? CmuxTheme.ink : CmuxTheme.muted)
                .frame(width: 44, height: 44)
                .background(CmuxTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!canPresent)
        .accessibilityIdentifier("TerminalFilesButton")
        .accessibilityLabel(String(
            localized: "terminal.artifact.button",
            defaultValue: "Show terminal files"
        ))
        .accessibilityHint(String(
            localized: "terminal.artifact.button_hint",
            defaultValue: "Shows recent uploads and files whose paths are visible in the active terminal."
        ))
    }

    private var canPresent: Bool {
        isEnabled && connection == .connected && store.identity != nil
    }

    private var phonePresentation: Binding<Bool> {
        Binding(
            get: { isPresentingFiles && !usesPopover },
            set: { if !$0 { dismissFiles() } }
        )
    }

    private var padPresentation: Binding<Bool> {
        Binding(
            get: { isPresentingFiles && usesPopover && !usesConstrainedWidthHarness },
            set: { if !$0 { dismissFiles() } }
        )
    }

    private var presentedFixtureReleaseAction: (() -> Void)? {
        #if DEBUG
        return qaState == "thumbnail-blocked" ? releaseStaleFixtureResponse : nil
        #else
        return nil
        #endif
    }

    private var usesConstrainedWidthHarness: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CMUX_UI_TEST_ARTIFACT_SCENARIO"] == "constrained-width"
        #else
        return false
        #endif
    }

    private func presentFiles() {
        guard canPresent else { return }
        #if DEBUG
        sheetDetent = ProcessInfo.processInfo.environment["CMUX_UI_TEST_ARTIFACT_SCENARIO"] == "failures"
            ? .large
            : .medium
        #else
        sheetDetent = .medium
        #endif
        isPresentingFiles = true
        if let identity = store.identity {
            Task { await store.activate(identity: identity) }
        }
    }

    private func dismissFiles() {
        guard isPresentingFiles || store.viewerURL != nil else { return }
        isPresentingFiles = false
        Task { await store.dismissViewer() }
    }

    private var activationID: String {
        [
            String(remoteFiles.hostGeneration),
            isEnabled ? "available" : "unavailable",
            connection == .connected ? "connected" : "disconnected",
            workspaceID ?? "none",
            surfaceID ?? "none",
        ].joined(separator: "|")
    }

    private func activate() async {
        await remoteFiles.activateArtifacts(
            isConnected: connection == .connected,
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
    }

    private var featureState: String {
        let availability = isEnabled ? "enabled" : "disabled"
        let surfaceID = store.identity?.surfaceID ?? "none"
        return "\(availability)|\(surfaceID)|\(artifactState)"
    }

    private var artifactState: String {
        switch store.state {
        case .idle: return "idle"
        case .loading: return "loading"
        case .ready: return "ready"
        case .unavailable: return "unavailable"
        case .failed: return "failed"
        }
    }

    private var terminalInvariant: String {
        let screen = surfaceStore.grid.rawRows
            .prefix(6)
            .joined(separator: "\\n")
        return "\(connectionState)|\(surfaceStore.subscribed ?? "none")|\(surfaceStore.rev)|\(inputState)|\(screen)"
    }

    private var connectionState: String {
        switch connection {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .error: return "error"
        }
    }

    private var inputState: String {
        switch surfaceStore.inputStatus {
        case .idle: return "idle"
        case .sending: return "sending"
        case .sent: return "sent"
        case .failed: return "failed"
        }
    }
}
