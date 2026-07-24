import SwiftUI
import UIKit

struct SettingsView: View {
    @Bindable var store: WorkspaceStore
    let onDisconnect: () -> Void
    let onReconnect: () -> Void
    let onTerminalPreferencesChanged: () -> Void
    var onTriggerTestNotification: (@MainActor () -> TestNotificationResult)? = nil
    @AppStorage("cmux.connectionMode") private var connectionModeRaw: String = ConnectionMode.direct.rawValue
    @AppStorage("cmux.host") private var host: String = ""
    @AppStorage("cmux.port") private var port: Int = 4399
    @AppStorage("cmux.brokerURL") private var brokerURL: String = ""
    @AppStorage("cmux.relayId") private var relayId: String = ""
    @AppStorage("cmux.pairingCode") private var pairingCode: String = ""
    @AppStorage("cmux.demoMode") private var demoMode: Bool = false
    @AppStorage("cmux.theme") private var themeRaw: String = CmuxColorTheme.storm.rawValue
    @AppStorage("cmux.terminalFontSize") private var terminalFontSize: Double = 15
    @AppStorage("cmux.terminalLineSpacing") private var terminalLineSpacing: Double = 2
    @AppStorage("cmux.terminalScanlines") private var terminalScanlines: Bool = true
    @AppStorage("cmux.terminalScanlineIntensity") private var scanlineIntensity: Double = 0.18
    @AppStorage("cmux.terminalHistoryLines") private var terminalHistoryLines: Int = 120
    @AppStorage("cmux.defaultLiveInput") private var defaultLiveInput: Bool = false
    @AppStorage("cmux.keepScreenAwake") private var keepScreenAwake: Bool = false
    @AppStorage("cmux.keepKeyboardAfterSubmit") private var keepKeyboardAfterSubmit: Bool = false
    @AppStorage("cmux.showTerminalShortcutBar") private var showTerminalShortcutBar: Bool = true
    @AppStorage("cmux.terminalHaptics") private var terminalHaptics: Bool = false
    @State private var localStatus: TestNotificationStatus = .idle
    @State private var roundTripStatus: TestNotificationStatus = .idle

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.string("settings"))
                        .cmuxDisplay(28)
                        .foregroundStyle(CmuxTheme.ink)

                    settingsMenuGroup(title: "settings connection") {
                        settingsMenuItem(.connection)
                    }

                    settingsMenuGroup(title: "settings preferences") {
                        settingsMenuItem(.appearance)
                        settingsMenuItem(.terminal)
                        settingsMenuItem(.interaction)
                    }

                    settingsMenuGroup(title: "settings tools") {
                        settingsMenuItem(.notifications)
                        settingsMenuItem(.demo)
                        settingsMenuItem(.device)
                    }
                }
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
            .scrollContentBackground(.hidden)
            .background(CmuxTheme.canvas)
            .navigationDestination(for: SettingsSection.self) { section in
                detailPage(for: section)
            }
        }
        .onAppear { CmuxTheme.apply(themeRawValue: themeRaw) }
        .onChange(of: themeRaw) { _, newValue in CmuxTheme.apply(themeRawValue: newValue) }
    }

    private func settingsMenuItem(_ section: SettingsSection) -> some View {
        NavigationLink(value: section) {
            HStack(spacing: 12) {
                Image(systemName: section.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(section.tint)
                    .frame(width: 28, height: 28)
                    .background(section.tint.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string(section.titleKey))
                        .cmuxMono(14, weight: .medium)
                        .foregroundStyle(CmuxTheme.ink)
                    Text(L10n.string(section.subtitleKey))
                        .cmuxMono(11)
                        .foregroundStyle(CmuxTheme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(CmuxTheme.muted)
            }
            .padding(14)
            .background(CmuxTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(CmuxTheme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(section.accessibilityIdentifier)
    }

    private func settingsMenuGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CmuxRule(title: L10n.string(title))
            content()
        }
    }

    @ViewBuilder
    private func detailPage(for section: SettingsSection) -> some View {
        switch section {
        case .connection:
            settingsDetail(title: section.titleKey) {
                connectionSettings
                connectionGuide
            }
        case .appearance:
            settingsDetail(title: section.titleKey) { appearanceSettings }
        case .terminal:
            settingsDetail(title: section.titleKey) { terminalSettings }
        case .interaction:
            settingsDetail(title: section.titleKey) { interactionSettings }
        case .notifications:
            settingsDetail(title: section.titleKey) { notificationSettings }
        case .demo:
            settingsDetail(title: section.titleKey) { demoSettings }
        case .device:
            settingsDetail(title: section.titleKey) { deviceSettings }
        }
    }

    private func settingsDetail<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(CmuxTheme.canvas)
        .navigationTitle(L10n.string(title))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var connectionSettings: some View {
        section(title: "connection") {
            VStack(alignment: .leading, spacing: 14) {
                labelRow("mode", color: CmuxTheme.muted)
                Picker(L10n.string("Connection mode"), selection: connectionModeBinding) {
                    ForEach(ConnectionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("ConnectionModePicker")

                if connectionMode == .direct {
                    labelRow("host", color: CmuxTheme.muted)
                    TextField("100.x.x.x or mac.tailnet.ts.net", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .cmuxInputStyle()

                    labelRow("port", color: CmuxTheme.muted)
                    Stepper(value: $port, in: 1024...65535) {
                        Text(String(port)).cmuxDisplay(14).foregroundStyle(CmuxTheme.accentBlue)
                    }
                } else {
                    labelRow("server url", color: CmuxTheme.muted)
                    TextField("https://relay.example.com", text: $brokerURL)
                        .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                        .cmuxInputStyle().accessibilityIdentifier("BrokerURLField")
                    labelRow("relay id", color: CmuxTheme.muted)
                    TextField("home-mac", text: $relayId)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .cmuxInputStyle().accessibilityIdentifier("RelayIDField")
                    labelRow("pairing code", color: CmuxTheme.muted)
                    SecureField(L10n.string("One-time pairing secret"), text: $pairingCode)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .cmuxInputStyle().accessibilityIdentifier("PairingCodeField")
                }

                HStack(spacing: 8) {
                    Circle().fill(color(for: store.connection)).frame(width: 6, height: 6)
                    Text(label(store.connection)).cmuxMono(11).foregroundStyle(CmuxTheme.muted)
                    Spacer()
                }

                Button(action: onReconnect) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold))
                        Text(L10n.string("[ SAVE & RECONNECT ]")).cmuxDisplay(12)
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
    }

    private var demoSettings: some View {
        section(title: "demo mode") {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("Mac이나 Tailscale 없이 앱을 둘러볼 수 있어요. 가짜 워크스페이스 / 터미널 / 알림이 채워집니다. App Review 평가 경로이기도 합니다."))
                    .cmuxMono(11).foregroundStyle(CmuxTheme.muted).fixedSize(horizontal: false, vertical: true)
                Button(action: { demoMode.toggle(); onReconnect() }) {
                    HStack(spacing: 8) {
                        Image(systemName: demoMode ? "checkmark.seal.fill" : "play.rectangle")
                            .font(.system(size: 12, weight: .bold))
                        Text(L10n.string(demoMode ? "[ EXIT DEMO MODE ]" : "[ TRY DEMO MODE ]")).cmuxDisplay(12)
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
    }

    private var notificationSettings: some View {
        section(title: "notifications") {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.string("Manage notification permission, banners, and sounds in iOS Settings."))
                    .cmuxMono(11).foregroundStyle(CmuxTheme.muted).fixedSize(horizontal: false, vertical: true)
                Button(action: openNotificationSettings) {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape").font(.system(size: 12, weight: .bold))
                        Text(L10n.string("Open iOS notification settings")).cmuxDisplay(12)
                    }
                    .foregroundStyle(CmuxTheme.ink)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(CmuxTheme.surfaceSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CmuxTheme.divider, lineWidth: 1))
                }
                .buttonStyle(.plain)

                if onTriggerTestNotification != nil {
                    Text(L10n.string("로컬 인젝션은 cmux 응답과 무관하게 Inbox + iOS 배너를 즉시 검증합니다. 라운드트립 라인은 relay → cmux → events.stream 경로 살아있는지 별도로 표시."))
                        .cmuxMono(11).foregroundStyle(CmuxTheme.muted).fixedSize(horizontal: false, vertical: true)
                    Button(action: triggerTestNotification) {
                        HStack(spacing: 8) {
                            Image(systemName: "bell.badge").font(.system(size: 12, weight: .bold))
                            Text(L10n.string("[ SEND TEST NOTIFICATION ]")).cmuxDisplay(12)
                        }
                        .foregroundStyle(CmuxTheme.canvas)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(CmuxTheme.accentBlue)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(localStatus.isSending || roundTripStatus.isSending)
                    if let line = localStatus.label { Text(L10n.format("local: %@", line)).cmuxMono(11).foregroundStyle(localStatus.color) }
                    if let line = roundTripStatus.label { Text(L10n.format("round-trip: %@", line)).cmuxMono(11).foregroundStyle(roundTripStatus.color) }
                }
            }
        }
    }

    private var deviceSettings: some View {
        section(title: "device") {
            Button(role: .destructive, action: onDisconnect) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                    Text(L10n.string("[ UNPAIR THIS DEVICE ]")).cmuxDisplay(12)
                }
                .foregroundStyle(CmuxTheme.accentRed)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(CmuxTheme.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CmuxTheme.accentRed.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var appearanceSettings: some View {
        section(title: "appearance") {
            VStack(alignment: .leading, spacing: 12) {
                labelRow("theme", color: CmuxTheme.muted)
                Picker(L10n.string("Theme"), selection: $themeRaw) {
                    ForEach(CmuxColorTheme.allCases) { theme in
                        Text(L10n.string(theme.titleKey)).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    ForEach(CmuxColorTheme.allCases) { theme in
                        Circle()
                            .fill(CmuxTheme.previewColor(for: theme))
                            .frame(width: 14, height: 14)
                            .overlay {
                                Circle().strokeBorder(
                                    themeRaw == theme.rawValue ? CmuxTheme.ink : Color.clear,
                                    lineWidth: 2
                                )
                            }
                        Text(L10n.string(theme.titleKey))
                            .cmuxMono(11)
                            .foregroundStyle(themeRaw == theme.rawValue ? CmuxTheme.ink : CmuxTheme.muted)
                        if theme != CmuxColorTheme.allCases.last { Spacer(minLength: 2) }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.string("Theme"))
            }
        }
    }

    private var terminalSettings: some View {
        section(title: "terminal") {
            VStack(alignment: .leading, spacing: 14) {
                preferenceSlider(
                    title: "Terminal font size",
                    value: $terminalFontSize,
                    range: 12...24,
                    step: 1
                )

                preferenceSlider(
                    title: "Line spacing",
                    value: $terminalLineSpacing,
                    range: 0...8,
                    step: 1
                )

                HStack {
                    Text(L10n.string("Terminal history"))
                        .cmuxMono(12)
                        .foregroundStyle(CmuxTheme.ink)
                    Spacer()
                    Stepper(value: $terminalHistoryLines, in: 60...400, step: 20) {
                        Text(L10n.format("%lld lines", Int64(terminalHistoryLines)))
                            .cmuxDisplay(10)
                            .foregroundStyle(CmuxTheme.accentBlue)
                    }
                    .accessibilityIdentifier("TerminalHistoryStepper")
                }
                .onChange(of: terminalHistoryLines) { _, _ in
                    onTerminalPreferencesChanged()
                }

                Toggle(L10n.string("Show CRT scanlines"), isOn: $terminalScanlines)
                    .tint(CmuxTheme.accentBlue)

                if terminalScanlines {
                    preferenceSlider(
                        title: "Scanline intensity",
                        value: $scanlineIntensity,
                        range: 0.06...0.30,
                        step: 0.02,
                        showsPoints: false
                    )
                }
            }
        }
    }

    private var interactionSettings: some View {
        section(title: "interaction") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(L10n.string("Use live input by default"), isOn: $defaultLiveInput)
                    .tint(CmuxTheme.accentBlue)
                Toggle(L10n.string("Keep keyboard open after sending"), isOn: $keepKeyboardAfterSubmit)
                    .tint(CmuxTheme.accentBlue)
                Toggle(L10n.string("Show terminal shortcut bar"), isOn: $showTerminalShortcutBar)
                    .tint(CmuxTheme.accentBlue)
                Toggle(L10n.string("Haptic feedback for terminal keys"), isOn: $terminalHaptics)
                    .tint(CmuxTheme.accentBlue)
                Toggle(L10n.string("Keep screen awake while using cmux Remote"), isOn: $keepScreenAwake)
                    .tint(CmuxTheme.accentBlue)

                Button(action: restoreAppearanceDefaults) {
                    Text(L10n.string("Restore preferences defaults"))
                        .cmuxDisplay(11)
                        .foregroundStyle(CmuxTheme.ink)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(CmuxTheme.surfaceSunken)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func preferenceSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        showsPoints: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.string(title))
                    .cmuxMono(12)
                    .foregroundStyle(CmuxTheme.ink)
                Spacer()
                Text(sliderValueLabel(value.wrappedValue, showsPoints: showsPoints))
                    .cmuxDisplay(10)
                    .foregroundStyle(CmuxTheme.accentBlue)
            }
            Slider(value: value, in: range, step: step)
                .tint(CmuxTheme.accentBlue)
        }
    }

    private func sliderValueLabel(_ value: Double, showsPoints: Bool) -> String {
        if showsPoints {
            return L10n.format("%lld pt", Int64(value.rounded()))
        }
        return L10n.format("%lld%%", Int64((value * 100).rounded()))
    }

    private func restoreAppearanceDefaults() {
        themeRaw = CmuxColorTheme.storm.rawValue
        terminalFontSize = 15
        terminalLineSpacing = 2
        terminalScanlines = true
        scanlineIntensity = 0.18
        terminalHistoryLines = 120
        defaultLiveInput = false
        keepScreenAwake = false
        keepKeyboardAfterSubmit = false
        showTerminalShortcutBar = true
        terminalHaptics = false
        CmuxTheme.apply(themeRawValue: themeRaw)
        onTerminalPreferencesChanged()
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CmuxRule(title: L10n.string(title))
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
        Text(L10n.string(text).uppercased())
            .cmuxDisplay(10)
            .foregroundStyle(color)
    }

    private var connectionMode: ConnectionMode {
        ConnectionMode(rawValue: connectionModeRaw) ?? .direct
    }

    private var connectionModeBinding: Binding<ConnectionMode> {
        Binding(
            get: { connectionMode },
            set: { connectionModeRaw = $0.rawValue }
        )
    }

    private var connectionGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            CmuxRule(title: L10n.string("tutorial"))
            VStack(alignment: .leading, spacing: 12) {
                if connectionMode == .direct {
                    GuideStep(number: 1,
                              title: "Mac에서 cmux와 Tailscale을 켭니다.",
                              detail: "iPhone과 Mac이 같은 tailnet에 있어야 합니다.")
                    GuideStep(number: 2,
                              title: "Mac 터미널에서 릴레이를 실행합니다.",
                              detail: "swift run cmux-relay serve --config ~/.cmuxremote/relay.json")
                    GuideStep(number: 3,
                              title: "Tailscale host와 port를 입력합니다.",
                              detail: "host는 100.x IP나 tailnet DNS, port는 보통 4399.")
                } else {
                    GuideStep(number: 1,
                              title: "VPS에서 Broker와 HTTPS를 실행합니다.",
                              detail: "broker/docker-compose.yml은 Caddy TLS를 함께 시작합니다.")
                    GuideStep(number: 2,
                              title: "Mac relay.json을 broker 모드로 설정합니다.",
                              detail: "서버와 같은 relay_id / relay_token을 사용합니다.")
                    GuideStep(number: 3,
                              title: "Server URL, Relay ID, Pairing Code를 입력합니다.",
                              detail: "공개 서버 주소는 https:// 로 시작해야 합니다.")
                }
                GuideStep(number: 4,
                          title: "저장 후 연결 다시 시도를 누릅니다.",
                          detail: "Workspaces가 보이면 연결이 완료된 상태입니다.")
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
        case .connected: return L10n.string("connected")
        case .connecting: return L10n.string("connecting…")
        case .error(let message): return L10n.format("error: %@", message)
        case .disconnected: return L10n.string("disconnected")
        }
    }

    private func triggerTestNotification() {
        guard let action = onTriggerTestNotification else { return }
        let result = action()
        localStatus = result.localInjected
            ? .sent
            : .failed(L10n.string("inject skipped"))
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
            roundTripStatus = .failed(L10n.string("relay disconnected"))
        }
    }
}

private extension View {
    func cmuxInputStyle() -> some View {
        self
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
    }
}

private enum SettingsSection: CaseIterable, Hashable {
    case connection, appearance, terminal, interaction, notifications, demo, device

    var titleKey: String {
        switch self {
        case .connection: return "connection"
        case .appearance: return "appearance"
        case .terminal: return "terminal"
        case .interaction: return "interaction"
        case .notifications: return "notifications"
        case .demo: return "demo mode"
        case .device: return "device"
        }
    }

    var subtitleKey: String {
        switch self {
        case .connection: return "Configure relay and pairing"
        case .appearance: return "Theme colors"
        case .terminal: return "Font, spacing and scanlines"
        case .interaction: return "Input and screen behavior"
        case .notifications: return "Test delivery and Inbox"
        case .demo: return "Preview without a relay"
        case .device: return "Pairing and credentials"
        }
    }

    var icon: String {
        switch self {
        case .connection: return "network"
        case .appearance: return "paintpalette"
        case .terminal: return "terminal"
        case .interaction: return "hand.tap"
        case .notifications: return "bell"
        case .demo: return "play.rectangle"
        case .device: return "iphone"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .connection: return "SettingsConnectionItem"
        case .appearance: return "SettingsAppearanceItem"
        case .terminal: return "SettingsTerminalItem"
        case .interaction: return "SettingsInteractionItem"
        case .notifications: return "SettingsNotificationsItem"
        case .demo: return "SettingsDemoItem"
        case .device: return "SettingsDeviceItem"
        }
    }

    var tint: Color {
        switch self {
        case .connection: return CmuxTheme.accentGreen
        case .appearance: return CmuxTheme.accentMagenta
        case .terminal: return CmuxTheme.accentBlue
        case .interaction: return CmuxTheme.accentCyan
        case .notifications: return CmuxTheme.accentYellow
        case .demo: return CmuxTheme.accentOrange
        case .device: return CmuxTheme.accentRed
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
        case .sending: return L10n.string("sending…")
        case .sent: return L10n.string("sent — Inbox에 곧 도착합니다.")
        case .failed(let message): return L10n.format("failed: %@", message)
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
                Text(L10n.string(title))
                    .cmuxMono(13, weight: .medium)
                    .foregroundStyle(CmuxTheme.ink)
                Text(L10n.string(detail))
                    .cmuxMono(11)
                    .foregroundStyle(CmuxTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
