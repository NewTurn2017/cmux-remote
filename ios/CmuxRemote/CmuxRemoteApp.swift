import SwiftUI
import SharedKit
import os.log

@main
struct CmuxRemoteApp: App {
    @State private var workspaceStore = WorkspaceStore(rpc: OfflineRPCDispatch())
    @State private var surfaceStore = SurfaceStore(rpc: OfflineRPCDispatch())
    @State private var notifStore = NotificationStore()
    @State private var notifPresenter = LocalNotificationPresenter()
    @State private var bootstrapped = false
    @State private var activeRPC: RPCClient?
    @State private var splashFinished = Self.shouldSkipSplash()
    @AppStorage("cmux.demoMode") private var demoMode: Bool = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView(
                    workspaceStore: workspaceStore,
                    surfaceStore: surfaceStore,
                    notifStore: notifStore,
                    onDisconnect: disconnect,
                    onReconnect: reconnect,
                    onTriggerTestNotification: triggerTestNotification
                )
                .task { await bootstrapOnce() }
                .onOpenURL(perform: handleDeepLink(_:))
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
        #if targetEnvironment(simulator) && DEBUG
        return true
        #else
        return false
        #endif
    }

    @MainActor
    private func bootstrapOnce() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        let presenter = notifPresenter
        notifStore.onNew = { record in presenter.present(record) }
        Task { await presenter.requestAuthorizationIfNeeded() }
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

        let auth = AuthClient(host: host, port: port, keychain: keychain, http: URLSessionHTTP(), scheme: "http")
        os_log("cmux register start host=%{public}@", host)
        do {
            try await auth.registerIfNeeded()
            os_log("cmux register ok")
        } catch {
            os_log("cmux register FAILED: %{public}@", String(describing: error))
            workspaceStore.connection = .error(String(describing: error))
            return
        }
        guard let token = try? keychain.get("bearer"),
              let deviceId = try? keychain.get("device_id"),
              let url = URL(string: "ws://\(host):\(port)/v1/ws")
        else { return }

        let ws = WSClient(url: url, headers: [
            "Sec-WebSocket-Protocol": "cmuxremote.v1",
            "Authorization": "Bearer \(token)",
        ])
        let rpc = RPCClient(transport: ws)
        let liveWorkspaceStore = WorkspaceStore(rpc: rpc)
        let liveSurfaceStore = SurfaceStore(rpc: rpc)
        await MainActor.run {
            workspaceStore = liveWorkspaceStore
            surfaceStore = liveSurfaceStore
            activeRPC = rpc
        }
        await rpc.onPush { frame in
            Task { @MainActor in
                liveSurfaceStore.ingest(frame)
                notifStore.ingest(frame)
            }
        }
        await ws.setOnText { text in Task { await rpc.handleIncoming(text: text) } }
        await ws.setOnClose { _ in
            Task {
                await rpc.failAllPending(RPCClientError.closed)
                await MainActor.run { liveWorkspaceStore.connection = .disconnected }
            }
        }
        await ws.setOnOpen {
            Task {
                let hello = HelloFrame(deviceId: deviceId, appVersion: "1.0.0", protocolVersion: 1)
                if let data = try? SharedKitJSON.deterministicEncoder.encode(hello),
                   let text = String(data: data, encoding: .utf8)
                {
                    await ws.send(text: text)
                }
                await liveSurfaceStore.resubscribe()
            }
        }
        await ws.connect()
        await liveWorkspaceStore.refresh()
    }

    @MainActor
    private func bootstrap(rpc: any RPCDispatch) async {
        workspaceStore = WorkspaceStore(rpc: rpc)
        surfaceStore = SurfaceStore(rpc: rpc)
        await workspaceStore.refresh()
    }

    @MainActor
    private func bootstrapDemo() async {
        let rpc = DemoRPCDispatch()
        let liveWorkspaceStore = WorkspaceStore(rpc: rpc)
        let liveSurfaceStore = SurfaceStore(rpc: rpc)
        workspaceStore = liveWorkspaceStore
        surfaceStore = liveSurfaceStore

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

        // Seed the inbox after a short beat so reviewers see notifications
        // without us racing the workspace list render.
        let store = notifStore
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for record in DemoContent.notifications() {
                store.append(record)
            }
        }
    }

    @MainActor
    private func reconnect() {
        let rpc = activeRPC
        activeRPC = nil
        workspaceStore.reset()
        surfaceStore.reset()
        bootstrapped = false
        Task { @MainActor in
            await rpc?.close()
            await bootstrapOnce()
        }
    }

    @MainActor
    private func disconnect() {
        let rpc = activeRPC
        Task { await rpc?.close() }
        activeRPC = nil
        try? Keychain(service: "com.genie.cmuxremote").wipe()
        workspaceStore.reset()
        surfaceStore.reset()
        bootstrapped = false
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
            title: "cmux 테스트 알림",
            subtitle: "Settings → SEND TEST NOTIFICATION",
            body: "Inbox에 쌓이고 백그라운드면 iOS 배너가 떠야 합니다.",
            ts: Int64(Date().timeIntervalSince1970),
            threadId: "workspace-\(workspaceId)"
        )
        notifStore.append(record)

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
        return TestNotificationResult(localInjected: true, roundTrip: roundTrip)
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

public struct TestNotificationResult: Sendable {
    public let localInjected: Bool
    public let roundTrip: Task<Void, Error>?
}

actor OfflineRPCDispatch: RPCDispatch {
    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        throw CmuxRemoteRPCError.rpc(code: "offline", message: "Configure Mac host in Settings")
    }
}

actor FakeRPCDispatch: RPCDispatch {
    private var surfaces: [(id: String, title: String)] = [("SF-FAKE", "shell")]

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        switch method {
        case "workspace.list":
            return RPCResponse(id: "fake", result: .object([
                "workspaces": .array([
                    .object(["id": .string("WS-FAKE"), "title": .string("Demo Workspace"), "index": .int(0)]),
                ]),
            ]))
        case "surface.list":
            return RPCResponse(id: "fake", result: .object([
                "surfaces": .array(surfaces.enumerated().map { index, surface in
                    .object([
                        "id": .string(surface.id),
                        "title": .string(surface.title),
                        "index": .int(Int64(index)),
                    ])
                }),
            ]))
        case "surface.create":
            let nextIndex = surfaces.count + 1
            let id = "SF-FAKE-\(nextIndex)"
            surfaces.append((id, "shell \(nextIndex)"))
            return RPCResponse(id: "fake", result: .object(["surface_id": .string(id)]))
        case "surface.close":
            if case .object(let params) = params,
               case .string(let surfaceId)? = params["surface_id"],
               surfaces.count > 1
            {
                surfaces.removeAll { $0.id == surfaceId }
            }
            return RPCResponse(id: "fake", ok: true, result: .object([:]))
        case "surface.subscribe", "surface.unsubscribe", "surface.send_text", "surface.send_key":
            return RPCResponse(id: "fake", ok: true, result: .object([:]))
        case "surface.read_text":
            return RPCResponse(id: "fake", result: .object(["text": .string("hello from fake relay")]))
        default:
            return RPCResponse(id: "fake", ok: true, result: .object([:]))
        }
    }
}
