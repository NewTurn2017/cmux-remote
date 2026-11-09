import SwiftUI
import SharedKit

struct SettingsRelayRows: View {
    let remoteFiles: RemoteFileFeatureCoordinator
    let isConnected: Bool
    @Environment(\.openURL) private var openURL
    @State private var confirmingUpdate = false

    private var relay: RelayVersionStore { remoteFiles.relayVersion }

    private var presentation: RelaySettingsPresentation {
        RelaySettingsPresentation(
            isConnected: isConnected,
            capabilitiesResolved: remoteFiles.capabilitiesResolved,
            supportsInfo: remoteFiles.capabilities.supportsRelayInfoV1,
            supportsUpdate: remoteFiles.capabilities.supportsRelayUpdateV1,
            info: relay.info,
            isLoading: relay.isLoading,
            isRequesting: relay.isRequesting,
            hasPendingRequest: relay.hasPendingRequest
        )
    }

    private var pollingKey: String {
        "\(remoteFiles.hostGeneration)|\(remoteFiles.capabilitiesResolved)|\(isConnected)|\(relay.requestCount)"
    }

    var body: some View {
        let presentation = presentation
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: "RELAY")
                    .cmuxDisplay(10)
                    .foregroundStyle(CmuxTheme.muted)
                Spacer()
                Text(verbatim: RelaySettingsText.version(presentation.version))
                    .cmuxDisplay(14)
                    .foregroundStyle(presentation.version == .legacy ? CmuxTheme.accentYellow : CmuxTheme.accentBlue)
                    .accessibilityIdentifier("SettingsRelayVersionValue")
            }

            if let status = presentation.status {
                Text(verbatim: RelaySettingsText.status(status))
                    .cmuxMono(11)
                    .foregroundStyle(color(for: status))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("SettingsRelayUpdateState")
            }

            if let enabled = presentation.autoUpdateEnabled {
                Text(verbatim: autoUpdateLine(enabled: enabled, lastCheckedAt: presentation.lastCheckedAt))
                    .cmuxMono(11)
                    .foregroundStyle(CmuxTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("SettingsRelayLastChecked")
            }

            if presentation.showsAdhocWarning {
                Text(String(
                    localized: "settings.relay.adhoc_warning",
                    defaultValue: "Ad-hoc signed: macOS may ask again for Downloads access after an update."
                ))
                    .cmuxMono(11)
                    .foregroundStyle(CmuxTheme.accentYellow)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("SettingsRelayAdhocWarning")
            }

            if presentation.showsManualGuide {
                manualGuide
            }

            if let failure = relay.requestFailure {
                Text(verbatim: RelaySettingsText.requestFailure(failure))
                    .cmuxMono(11)
                    .foregroundStyle(CmuxTheme.accentRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("SettingsRelayRequestFailure")
            }

            if let outcome = relay.outcome {
                Text(verbatim: RelaySettingsText.outcome(outcome))
                    .cmuxMono(11)
                    .foregroundStyle(outcome == .timedOut ? CmuxTheme.accentYellow : CmuxTheme.accentGreen)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("SettingsRelayUpdateResult")
            }

            if presentation.updateButton != .hidden {
                updateNowButton(enabled: presentation.updateButton == .enabled)
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 0) {
                testMarker("SettingsRelayVersionMarker", value: presentation.versionAccessibilityValue)
                if presentation.status != nil {
                    testMarker("SettingsRelayUpdateStateMarker", value: "state=\(presentation.stateRawValue ?? "none")")
                }
            }
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SettingsRelaySection")
        .task(id: pollingKey) {
            if isConnected, !remoteFiles.capabilitiesResolved {
                await remoteFiles.retryCapabilitiesIfUnresolved()
            }
            guard RelaySettingsPresentation.shouldQueryInfo(
                isConnected: isConnected,
                capabilitiesResolved: remoteFiles.capabilitiesResolved,
                supportsInfo: remoteFiles.capabilities.supportsRelayInfoV1
            ) else { return }
            let hostID = remoteFiles.hostID
            await relay.refresh(hostID: hostID)
            await relay.pollWhileInProgress(hostID: hostID)
        }
        .alert(
            String(localized: "settings.relay.confirm.title", defaultValue: "Update the relay now?"),
            isPresented: $confirmingUpdate
        ) {
            Button(String(localized: "settings.relay.confirm.action", defaultValue: "Update")) {
                Task { await relay.startUpdate() }
            }
            Button(String(localized: "settings.relay.confirm.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(
                localized: "settings.relay.confirm.message",
                defaultValue: "The relay restarts after the update, so this phone disconnects briefly and reconnects automatically."
            ))
        }
    }

    /// A 1x1 element that carries a machine value for UI tests, like `TerminalViewportBackground`,
    /// so the visible rows keep human-readable accessibility.
    private func testMarker(_ identifier: String, value: String) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(value)
    }

    private var manualGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(
                localized: "settings.relay.manual_guide",
                defaultValue: "To update, run git pull and then ./scripts/install-launchd.sh on your Mac."
            ))
                .cmuxMono(11)
                .foregroundStyle(CmuxTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("SettingsRelayManualUpdateGuide")

            Button {
                openURL(RelaySettingsText.manualUpdateURL)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .bold))
                    Text(String(localized: "settings.relay.manual_link", defaultValue: "Setup guide (README)"))
                        .cmuxMono(11, weight: .medium)
                }
                .foregroundStyle(CmuxTheme.accentBlue)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("SettingsRelayManualUpdateLink")
        }
    }

    private func updateNowButton(enabled: Bool) -> some View {
        Button {
            confirmingUpdate = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .bold))
                Text(verbatim: "[ UPDATE NOW ]")
                    .cmuxDisplay(12)
            }
            .foregroundStyle(enabled ? CmuxTheme.canvas : CmuxTheme.muted)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(enabled ? CmuxTheme.accentBlue : CmuxTheme.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("SettingsRelayUpdateNowButton")
    }

    private func autoUpdateLine(enabled: Bool, lastCheckedAt: Date?) -> String {
        let autoUpdate = RelaySettingsText.autoUpdate(enabled: enabled)
        guard let lastCheckedAt else { return autoUpdate }
        return "\(autoUpdate) · \(RelaySettingsText.lastChecked(lastCheckedAt, relativeTo: Date()))"
    }

    private func color(for status: RelaySettingsPresentation.Status) -> Color {
        switch status {
        case .upToDate: return CmuxTheme.accentGreen
        case .available, .staged: return CmuxTheme.accentYellow
        case .failed: return CmuxTheme.accentRed
        default: return CmuxTheme.muted
        }
    }
}
