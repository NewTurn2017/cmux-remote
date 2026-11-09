import SwiftUI

struct SettingsVersionSection: View {
    @Bindable var appStoreUpdates: AppStoreUpdateStore
    let remoteFiles: RemoteFileFeatureCoordinator
    let isConnected: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: "APP")
                    .cmuxDisplay(10)
                    .foregroundStyle(CmuxTheme.muted)
                Spacer()
                Text(verbatim: appStoreUpdates.installed.displayText)
                    .cmuxDisplay(14)
                    .foregroundStyle(CmuxTheme.accentBlue)
                    .accessibilityIdentifier("SettingsAppVersionValue")
            }

            if let update = appStoreUpdates.availableUpdate {
                Text(String(
                    localized: "settings.version.app_store_available",
                    defaultValue: "Version \(update.version) is available on the App Store."
                ))
                    .cmuxMono(11)
                    .foregroundStyle(CmuxTheme.accentYellow)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("SettingsAppStoreUpdateNotice")

                Button {
                    openURL(update.url)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 12, weight: .bold))
                        Text(verbatim: "[ OPEN APP STORE ]")
                            .cmuxDisplay(12)
                    }
                    .foregroundStyle(CmuxTheme.canvas)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(CmuxTheme.accentYellow)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("SettingsAppStoreUpdateButton")
            }

            Rectangle()
                .fill(CmuxTheme.divider)
                .frame(height: 1)

            SettingsRelayRows(remoteFiles: remoteFiles, isConnected: isConnected)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SettingsVersionSection")
        .task { await appStoreUpdates.checkIfDue() }
        .onAppear { appStoreUpdates.markSeen() }
        .onChange(of: appStoreUpdates.availableUpdate?.version) { _, _ in
            appStoreUpdates.markSeen()
        }
    }
}
