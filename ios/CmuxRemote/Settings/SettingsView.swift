import SwiftUI

struct SettingsView: View {
    @Bindable var store: WorkspaceStore
    let onDisconnect: () -> Void
    let onReconnect: () -> Void
    var onTriggerTestNotification: (@MainActor () -> TestNotificationResult)? = nil
    @AppStorage("cmux.host") private var host: String = ""
    @AppStorage("cmux.port") private var port: Int = 4399
    @AppStorage("cmux.demoMode") private var demoMode: Bool = false
    @AppStorage("cmux.localNotificationsEnabled") private var localNotificationsEnabled: Bool = true
    @State private var localStatus: TestNotificationStatus = .idle
    @State private var roundTripStatus: TestNotificationStatus = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("settings")
                    .cmuxDisplay(28)
                    .foregroundStyle(CmuxTheme.ink)

                connectionGuide

                section(title: "demo mode") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(
                            localized: "settings.demo.description",
                            defaultValue: "Explore the app without a Mac or Tailscale. Demo workspaces, terminals, and notifications are preloaded. This is also the App Review evaluation path."
                        ))
                            .cmuxMono(11)
                            .foregroundStyle(CmuxTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)

                        Button(action: { demoMode.toggle(); onReconnect() }) {
                            HStack(spacing: 8) {
                                Image(systemName: demoMode ? "checkmark.seal.fill" : "play.rectangle")
                                    .font(.system(size: 12, weight: .bold))
                                Text(demoMode ? "[ EXIT DEMO MODE ]" : "[ TRY DEMO MODE ]")
                                    .cmuxDisplay(12)
                            }
                            .foregroundStyle(CmuxTheme.canvas)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(demoMode ? CmuxTheme.accentYellow : CmuxTheme.accentBlue)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("DemoModeToggle")
                    }
                }

                section(title: "mac connection") {
                    VStack(alignment: .leading, spacing: 14) {
                        labelRow("host", color: CmuxTheme.muted)
                        TextField("100.x.x.x or mac.tailnet.ts.net", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .cmuxMono(13)
                            .foregroundStyle(CmuxTheme.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(CmuxTheme.surfaceSunken)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                            )

                        labelRow("port", color: CmuxTheme.muted)
                        Stepper(value: $port, in: 1024...65535) {
                            Text(String(port))
                                .cmuxDisplay(14)
                                .foregroundStyle(CmuxTheme.accentBlue)
                        }

                        HStack(spacing: 8) {
                            Circle()
                                .fill(color(for: store.connection))
                                .frame(width: 6, height: 6)
                            Text(label(store.connection))
                                .cmuxMono(11)
                                .foregroundStyle(CmuxTheme.muted)
                            Spacer()
                        }

                        Button(action: onReconnect) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .bold))
                                Text("[ SAVE & RECONNECT ]")
                                    .cmuxDisplay(12)
                            }
                            .foregroundStyle(CmuxTheme.canvas)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(CmuxTheme.accentGreen)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ReconnectButton")
                    }
                }

                section(title: "notifications") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $localNotificationsEnabled) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("LOCAL IOS NOTIFICATIONS")
                                    .cmuxDisplay(11)
                                    .foregroundStyle(CmuxTheme.ink)
                                Text(String(
                                    localized: "settings.notifications.description",
                                    defaultValue: "Only events that require your input appear as iOS banners. Inbox history and badges remain available."
                                ))
                                    .cmuxMono(11)
                                    .foregroundStyle(CmuxTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(CmuxTheme.accentGreen)
                        .accessibilityIdentifier("LocalNotificationsEnabledToggle")

                        if onTriggerTestNotification != nil {
                            Text(String(
                                localized: "settings.notifications.test_description",
                                defaultValue: "Local injection appears in Inbox immediately without waiting for cmux. An iOS banner is requested only when the setting above is enabled. The round-trip status separately verifies the relay → cmux → events.stream path."
                            ))
                                .cmuxMono(11)
                                .foregroundStyle(CmuxTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)

                            Button(action: triggerTestNotification) {
                                HStack(spacing: 8) {
                                    Image(systemName: "bell.badge")
                                        .font(.system(size: 12, weight: .bold))
                                    Text("[ SEND TEST NOTIFICATION ]")
                                        .cmuxDisplay(12)
                                }
                                .foregroundStyle(CmuxTheme.canvas)
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(CmuxTheme.accentBlue)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(localStatus.isSending || roundTripStatus.isSending)

                            if let line = localStatus.label {
                                Text("local: \(line)")
                                    .cmuxMono(11)
                                    .foregroundStyle(localStatus.color)
                            }
                            if let line = roundTripStatus.label {
                                Text("round-trip: \(line)")
                                    .cmuxMono(11)
                                    .foregroundStyle(roundTripStatus.color)
                            }
                        }
                    }
                }

                section(title: "device") {
                    Button(role: .destructive, action: onDisconnect) {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                            Text("[ UNPAIR THIS DEVICE ]")
                                .cmuxDisplay(12)
                        }
                        .foregroundStyle(CmuxTheme.accentRed)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(CmuxTheme.surfaceSunken)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(CmuxTheme.accentRed.opacity(0.45), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(CmuxTheme.canvas)
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CmuxRule(title: title)
            content()
        }
        .padding(14)
        .background(CmuxTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        )
    }

    private func labelRow(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .cmuxDisplay(10)
            .foregroundStyle(color)
    }

    private var connectionGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            CmuxRule(title: "tutorial")
            VStack(alignment: .leading, spacing: 12) {
                GuideStep(number: 1,
                          title: String(
                              localized: "settings.guide.step1.title",
                              defaultValue: "Start cmux and Tailscale on your Mac."
                          ),
                          detail: String(
                              localized: "settings.guide.step1.detail",
                              defaultValue: "Your iPhone and Mac must be on the same tailnet."
                          ))
                GuideStep(number: 2,
                          title: String(
                              localized: "settings.guide.step2.title",
                              defaultValue: "Start the relay in Terminal on your Mac."
                          ),
                          detail: "swift run cmux-relay serve --config ~/.cmuxremote/relay.json")
                GuideStep(number: 3,
                          title: String(
                              localized: "settings.guide.step3.title",
                              defaultValue: "Make the listen address in relay.json reachable."
                          ),
                          detail: String(
                              localized: "settings.guide.step3.detail",
                              defaultValue: "A physical device requires binding to 0.0.0.0:4399 or your Tailscale IP."
                          ))
                GuideStep(number: 4,
                          title: String(
                              localized: "settings.guide.step4.title",
                              defaultValue: "Enter the host and port under Mac Connection."
                          ),
                          detail: String(
                              localized: "settings.guide.step4.detail",
                              defaultValue: "Use a 100.x Tailscale IP or tailnet DNS name. The default port is 4399."
                          ))
                GuideStep(number: 5,
                          title: String(
                              localized: "settings.guide.step5.title",
                              defaultValue: "Select Save & Reconnect."
                          ),
                          detail: String(
                              localized: "settings.guide.step5.detail",
                              defaultValue: "When Workspaces appear, you are connected. If not, check the relay and Tailscale on your Mac."
                          ))
            }
        }
        .padding(14)
        .background(CmuxTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        )
    }

    private func color(for state: ConnectionState) -> Color {
        switch state {
        case .connected:    return CmuxTheme.accentGreen
        case .connecting:   return CmuxTheme.accentYellow
        case .error:        return CmuxTheme.accentRed
        case .disconnected: return CmuxTheme.muted
        }
    }

    private func label(_ state: ConnectionState) -> String {
        switch state {
        case .connected: return "connected"
        case .connecting: return "connecting…"
        case .error(let message): return "error: \(message)"
        case .disconnected: return "disconnected"
        }
    }

    private func triggerTestNotification() {
        guard let action = onTriggerTestNotification else { return }
        let result = action()
        localStatus = result.localBannerRequested
            ? .sent
            : .failed("local notifications disabled; Inbox only")
        if let task = result.roundTrip {
            roundTripStatus = .sending
            Task { @MainActor in
                do {
                    try await task.value
                    roundTripStatus = .sent
                } catch {
                    roundTripStatus = .failed(String(describing: error))
                }
            }
        } else {
            roundTripStatus = .failed("relay disconnected")
        }
    }
}

private enum TestNotificationStatus: Equatable {
    case idle
    case sending
    case sent
    case failed(String)

    var isSending: Bool {
        if case .sending = self { return true }
        return false
    }

    var label: String? {
        switch self {
        case .idle: return nil
        case .sending: return "sending…"
        case .sent:
            return String(
                localized: "settings.notifications.test_sent",
                defaultValue: "sent — arriving in Inbox shortly"
            )
        case .failed(let message): return "failed: \(message)"
        }
    }

    var color: Color {
        switch self {
        case .failed: return CmuxTheme.accentRed
        case .sent: return CmuxTheme.accentGreen
        default: return CmuxTheme.muted
        }
    }
}

private struct GuideStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%02d", number))
                .cmuxDisplay(11)
                .foregroundStyle(CmuxTheme.accentGreen)
                .frame(width: 22, height: 22)
                .background(CmuxTheme.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .cmuxMono(13, weight: .medium)
                    .foregroundStyle(CmuxTheme.ink)
                Text(detail)
                    .cmuxMono(11)
                    .foregroundStyle(CmuxTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
