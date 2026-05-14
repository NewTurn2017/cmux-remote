import SwiftUI

struct SettingsView: View {
    @Bindable var store: WorkspaceStore
    let onDisconnect: () -> Void
    let onReconnect: () -> Void
    var onTriggerTestNotification: (@MainActor () -> TestNotificationResult)? = nil
    @AppStorage("cmux.host") private var host: String = ""
    @AppStorage("cmux.port") private var port: Int = 4399
    @State private var localStatus: TestNotificationStatus = .idle
    @State private var roundTripStatus: TestNotificationStatus = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("settings")
                    .cmuxDisplay(28)
                    .foregroundStyle(CmuxTheme.ink)

                connectionGuide

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

                if onTriggerTestNotification != nil {
                    section(title: "notifications") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("로컬 인젝션은 cmux 응답과 무관하게 Inbox + iOS 배너를 즉시 검증합니다. 라운드트립 라인은 relay → cmux → events.stream 경로 살아있는지 별도로 표시.")
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
                          title: "Mac에서 cmux와 Tailscale을 켭니다.",
                          detail: "iPhone과 Mac이 같은 tailnet에 있어야 합니다.")
                GuideStep(number: 2,
                          title: "Mac 터미널에서 릴레이를 실행합니다.",
                          detail: "swift run cmux-relay serve --config ~/.cmuxremote/relay.json")
                GuideStep(number: 3,
                          title: "relay.json의 listen을 열어둡니다.",
                          detail: "실기기 연결은 0.0.0.0:4399 또는 Tailscale IP 바인딩이 필요합니다.")
                GuideStep(number: 4,
                          title: "아래 Mac 연결에 host와 port를 입력합니다.",
                          detail: "host는 100.x Tailscale IP나 tailnet DNS, port는 보통 4399.")
                GuideStep(number: 5,
                          title: "저장 후 연결 다시 시도를 누릅니다.",
                          detail: "Workspaces가 보이면 완료. 실패 시 Mac 릴레이/Tailscale 상태 확인.")
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
        localStatus = result.localInjected
            ? .sent
            : .failed("inject skipped")
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
        case .sent: return "sent — Inbox에 곧 도착합니다."
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
