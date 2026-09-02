import SwiftUI
import SharedKit
import os.log

@main
struct CmuxRemoteApp: App {
    @UIApplicationDelegateAdaptor(RemoteNotificationRegistrar.self) private var remoteNotifications
    @State private var workspaceStore = WorkspaceStore(rpc: OfflineRPCDispatch())
    @State private var surfaceStore = SurfaceStore(rpc: OfflineRPCDispatch())
    @State private var notifStore = NotificationStore()
    @State private var hostStatusStore = HostStatusStore(rpc: OfflineRPCDispatch())
    @State private var remoteFiles: RemoteFileFeatureCoordinator
    @State private var notifPresenter = LocalNotificationPresenter()
    @State private var bootstrapped = false
    @State private var activeSession: LiveRelaySession?
    @State private var activeRPC: RPCClient?
    @State private var splashFinished = Self.shouldSkipSplash()
    @AppStorage("cmux.demoMode") private var demoMode: Bool = false
    @AppStorage("cmux.localNotificationsEnabled") private var localNotificationsEnabled: Bool = true

    init() {
        let routingRPC = OfflineRPCDispatch()
        let attachmentStore = AttachmentStore(rpc: routingRPC)
        let attachments = AttachmentCoordinator(
            store: attachmentStore,
            photoStager: FoundationAttachmentPhotoStager()
        )
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("TerminalArtifacts", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("TerminalArtifacts", isDirectory: true)
        let terminalArtifacts = TerminalArtifactStore(
            rpc: routingRPC,
            cache: TerminalArtifactCache(rootURL: cacheRoot)
        )
        _remoteFiles = State(initialValue: RemoteFileFeatureCoordinator(
            routingRPC: routingRPC,
            attachments: attachments,
            terminalArtifacts: terminalArtifacts
        ))
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView(
                    workspaceStore: workspaceStore,
                    surfaceStore: surfaceStore,
                    notifStore: notifStore,
                    hostStatusStore: hostStatusStore,
                    remoteFiles: remoteFiles,
                    onDisconnect: disconnect,
                    onReconnect: reconnect,
                    onTriggerTestNotification: triggerTestNotification
                )
                .modifier(TerminalArtifactDebugWidthHarness())
                .task { await bootstrapOnce() }
                .onOpenURL(perform: handleDeepLink(_:))
                .onChange(of: localNotificationsEnabled) { _, enabled in
                    notifStore.localNotificationsEnabled = enabled
                    if enabled {
                        Task { @MainActor in
                            guard await notifPresenter.requestAuthorizationIfNeeded() else { return }
                            await remoteNotifications.registerForRemoteNotifications()
                        }
                    }
                }
                .opacity(splashFinished ? 1 : 0)

                if !splashFinished {
                    SplashView {
                        withAnimation(.easeOut(duration: 0.22)) {
                            splashFinished = true
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private static func shouldSkipSplash() -> Bool {
        let info = ProcessInfo.processInfo
        return info.environment["CMUX_SKIP_SPLASH"] == "1"
            || info.arguments.contains("--cmux-skip-splash")
    }

    private static func shouldUseFakeRelay(_ info: ProcessInfo) -> Bool {
        #if DEBUG
        // Explicit opt-out wins so a sim can still smoke a real relay.
        if info.environment["CMUX_REAL_RELAY"] == "1"
            || info.arguments.contains("--cmux-real-relay")
        {
            return false
        }
        if info.environment["CMUX_FAKE_RELAY"] == "1"
            || info.arguments.contains("--cmux-fake-relay")
        {
            return true
        }
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
        #else
        return false
        #endif
    }

    @MainActor
    private func bootstrapOnce() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        let presenter = notifPresenter
        notifStore.localNotificationsEnabled = localNotificationsEnabled
        notifStore.onNew = { record in presenter.present(record) }
        if localNotificationsEnabled {
            Task { await presenter.requestAuthorizationIfNeeded() }
        }
        let processInfo = ProcessInfo.processInfo
        if demoMode || Self.shouldUseFakeRelay(processInfo) {
            await bootstrapDemo()
            return
        }

        let keychain = Keychain(service: "com.genie.cmuxremote")
        if !Self.shouldSkipHardeningForDevelopment(
            environment: processInfo.environment,
            arguments: processInfo.arguments
        ) {
            let result = HardeningCheck(keychain: keychain).runAtLaunch()
            guard result == .ok else { return }
        }

        // Env vars beat UserDefaults so the simulator can seed config via
        // `SIMCTL_CHILD_CMUX_HOST=...` even when NSUserDefaults launch-arg
        // overrides silently fail on iOS Simulator.
        let envHost = processInfo.environment["CMUX_HOST"] ?? ""
        let envPort = Int(processInfo.environment["CMUX_PORT"] ?? "") ?? 0
        let host = !envHost.isEmpty
            ? envHost
            : (UserDefaults.standard.string(forKey: "cmux.host") ?? "")
        let port: Int
        if envPort > 0 {
            port = envPort
        } else {
            let defaultsPort = UserDefaults.standard.integer(forKey: "cmux.port")
            port = defaultsPort == 0 ? 4399 : defaultsPort
        }
        os_log("cmux bootstrap host=%{public}@ port=%{public}d", host, port)
        guard !host.isEmpty else { return }
        guard EndpointPolicy.isAllowedRelayHost(host) else {
            workspaceStore.connection = .error("Tailscale host or 100.64.0.0/10 address required")
            return
        }

        let session = LiveRelaySession(
            host: host,
            port: port,
            keychain: keychain,
            remoteFiles: remoteFiles,
            notificationStore: notifStore,
            notificationRegistrar: remoteNotifications
        )
        activeSession = session
        workspaceStore.connection = .connecting
        session.connect(
            localNotificationsEnabled: localNotificationsEnabled,
            onStoresReady: { stores, rpc in
                workspaceStore = stores.workspace
                surfaceStore = stores.surface
                hostStatusStore = stores.hostStatus
                activeRPC = rpc
            },
            onClosed: { rpc, code in
                guard activeRPC === rpc else { return }
                workspaceStore.connection = code == 4401
                    ? .error(Self.connectionMessage(for: .pairingRemoved))
                    : .disconnected
                await remoteFiles.deactivate(purgeAccountCache: false)
            },
            onRetryWaiting: { _ in
                workspaceStore.connection = .recovering
            },
            onFailure: { error in
                guard activeSession === session else { return }
                workspaceStore.connection = .error(Self.connectionMessage(for: error))
            }
        )
    }

    @MainActor
    private func bootstrapDemo() async {
        let processInfo = ProcessInfo.processInfo
        #if DEBUG
        let fileFeatureFixtures = processInfo.environment["CMUX_UI_TEST_FILE_FEATURE_FIXTURES"] == "1"
        let staleFeatureGate = fileFeatureFixtures
            && processInfo.environment["CMUX_UI_TEST_FILE_FEATURE_STALE_GATE"] == "1"
        let rpc = DemoRPCDispatch(
            fileFeatureFixturesEnabled: fileFeatureFixtures,
            staleFeatureResponseGateEnabled: staleFeatureGate,
            attachmentScenario: processInfo.environment["CMUX_UI_TEST_ATTACHMENT_SCENARIO"],
            artifactScenario: processInfo.environment["CMUX_UI_TEST_ARTIFACT_SCENARIO"],
            fileFeatureCacheNamespace: processInfo.environment["CMUX_UI_TEST_FILE_FEATURE_CACHE_NAMESPACE"]
        )
        #else
        let rpc = DemoRPCDispatch()
        #endif
        let liveWorkspaceStore = WorkspaceStore(rpc: rpc)
        let liveSurfaceStore = SurfaceStore(rpc: rpc)
        let liveHostStatusStore = HostStatusStore(rpc: rpc)
        liveWorkspaceStore.onWorkspaceAlert = { notifStore.append($0, deliveryPolicy: .userInputRequired) }
        workspaceStore = liveWorkspaceStore
        surfaceStore = liveSurfaceStore
        hostStatusStore = liveHostStatusStore
        #if DEBUG
        remoteFiles.configureFixtureQA(
            state: staleFeatureGate ? "arming" : nil,
            release: staleFeatureGate ? {
                remoteFiles.setQAState("releasing")
                Task { @MainActor in
                    await rpc.releaseStaleFileFeatureResponse()
                    remoteFiles.setQAState(DemoContent.fileFeatureQAStateReleased)
                }
            } : nil
        )
        if fileFeatureFixtures {
            await rpc.setOnFileFeatureQAState { state in
                await MainActor.run { remoteFiles.setQAState(state) }
            }
        }
        #else
        remoteFiles.configureFixtureQA(state: nil, release: nil)
        #endif
        await remoteFiles.connect(
            rpc: rpc,
            hostID: "demo-host",
            accountScope: "demo-account"
        )

        // When the user taps a surface chip, push a corresponding screen.full
        // so the terminal mirror lights up just like the live path would.
        await rpc.setOnSubscribe { surfaceId in
            await MainActor.run {
                if let frame = DemoContent.screenFull(for: surfaceId) {
                    liveSurfaceStore.ingest(.screenFull(frame))
                }
            }
        }

        await liveWorkspaceStore.refresh()
        await liveHostStatusStore.refreshBattery()

        // Seed the inbox after a short beat so reviewers see notifications
        // without us racing the workspace list render.
        let store = notifStore
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for record in DemoContent.notifications() {
                store.append(record, deliveryPolicy: .inboxOnly)
            }
        }
    }

    @MainActor
    private func reconnect() {
        let session = activeSession
        activeSession = nil
        activeRPC = nil
        workspaceStore.reset()
        surfaceStore.reset()
        hostStatusStore.reset()
        bootstrapped = false
        Task { @MainActor in
            await remoteFiles.deactivate(purgeAccountCache: false)
            await session?.close()
            await bootstrapOnce()
        }
    }

    @MainActor
    private func disconnect() {
        let session = activeSession
        activeSession = nil
        activeRPC = nil
        try? Keychain(service: "com.genie.cmuxremote").wipe()
        workspaceStore.reset()
        surfaceStore.reset()
        hostStatusStore.reset()
        bootstrapped = false
        Task { @MainActor in
            await remoteFiles.deactivate(purgeAccountCache: true)
            await session?.close()
        }
    }

    private static func connectionMessage(for error: AuthError) -> String {
        switch error {
        case .pairingRemoved:
            return String(
                localized: "connection.error.pairing_removed",
                defaultValue: "Pairing was removed on the Mac. Select Unpair This Device, then reconnect."
            )
        case .registrationDenied:
            return String(
                localized: "connection.error.registration_denied",
                defaultValue: "This Tailscale account is not allowed by the Mac relay."
            )
        case .relayUnavailable:
            return String(
                localized: "connection.error.relay_unavailable",
                defaultValue: "The Mac relay is waiting for Tailscale and will retry automatically."
            )
        case .disallowedHost:
            return String(
                localized: "connection.error.disallowed_host",
                defaultValue: "Enter a Tailscale IP or tailnet DNS name."
            )
        case .transport:
            return String(
                localized: "connection.error.transport",
                defaultValue: "The Mac relay is unreachable."
            )
        default:
            return String(
                localized: "connection.error.generic",
                defaultValue: "The relay returned an invalid response."
            )
        }
    }

    private func handleDeepLink(_ url: URL) {
        // cmux://surface/<id> will land with APNs/deep-link handling in M6.
    }

    @MainActor
    private func triggerTestNotification() -> TestNotificationResult {
        let workspaceId = workspaceStore.selectedId
            ?? workspaceStore.workspaces.first?.id
            ?? "test-workspace"
        let id = "local-test-\(UUID().uuidString)"
        let record = NotificationRecord(
            id: id,
            workspaceId: workspaceId,
            surfaceId: nil,
            title: String(
                localized: "notification.test.title",
                defaultValue: "cmux test notification"
            ),
            subtitle: "Settings → SEND TEST NOTIFICATION",
            body: String(
                localized: "notification.test.body",
                defaultValue: "This should appear in Inbox and as an iOS banner while the app is in the background."
            ),
            ts: Int64(Date().timeIntervalSince1970),
            threadId: "workspace-\(workspaceId)"
        )
        let shouldRequestLocalBanner = localNotificationsEnabled
        notifStore.localNotificationsEnabled = shouldRequestLocalBanner
        notifStore.append(
            record,
            deliveryPolicy: shouldRequestLocalBanner ? .userInitiatedTest : .inboxOnly
        )

        let roundTrip: Task<Void, Error>?
        if let rpc = activeRPC {
            roundTrip = Task {
                let response = try await rpc.call(method: "notification.create", params: .object([
                    "workspace_id": .string(workspaceId),
                    "title": .string("cmux round-trip"),
                    "body": .string("relay → cmux → events.stream → iOS"),
                ]))
                _ = try response.requireOk()
            }
        } else {
            roundTrip = nil
        }
        return TestNotificationResult(localBannerRequested: shouldRequestLocalBanner, roundTrip: roundTrip)
    }

    static func shouldSkipHardeningForDevelopment(
        environment: [String: String],
        arguments: [String] = []
    ) -> Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
