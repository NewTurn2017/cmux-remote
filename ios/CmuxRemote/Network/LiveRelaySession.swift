import Foundation
import SharedKit

@MainActor
final class LiveRelaySession {
    struct Stores {
        let workspace: WorkspaceStore
        let surface: SurfaceStore
        let hostStatus: HostStatusStore
    }

    private let host: String
    private let port: Int
    private let auth: AuthClient
    private let remoteFiles: RemoteFileFeatureCoordinator
    private let notificationStore: NotificationStore
    private let notificationRegistrar: RemoteNotificationRegistrar
    private let credentialRetrier: RelayCredentialRetrier
    private var generation: UInt64 = 0
    private var preparationTask: Task<Void, Never>?
    private(set) var rpc: RPCClient?

    init(
        host: String,
        port: Int,
        keychain: Keychain,
        remoteFiles: RemoteFileFeatureCoordinator,
        notificationStore: NotificationStore,
        notificationRegistrar: RemoteNotificationRegistrar,
        credentialRetrier: RelayCredentialRetrier = RelayCredentialRetrier()
    ) {
        self.host = host
        self.port = port
        auth = AuthClient(
            host: host,
            port: port,
            keychain: keychain,
            http: URLSessionHTTP()
        )
        self.remoteFiles = remoteFiles
        self.notificationStore = notificationStore
        self.notificationRegistrar = notificationRegistrar
        self.credentialRetrier = credentialRetrier
    }

    func connect(
        localNotificationsEnabled: Bool,
        onStoresReady: @escaping @MainActor (Stores, RPCClient) -> Void,
        onClosed: @escaping @MainActor (RPCClient, Int) async -> Void,
        onRetryWaiting: @escaping @MainActor (TimeInterval) -> Void,
        onFailure: @escaping @MainActor (AuthError) -> Void
    ) {
        generation &+= 1
        let currentGeneration = generation
        preparationTask?.cancel()
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let credentials = try await credentialRetrier.prepare(
                    using: auth,
                    while: { [weak self] in
                        guard let self else { return false }
                        return !Task.isCancelled && self.generation == currentGeneration
                    },
                    onWaiting: { seconds in
                        onRetryWaiting(seconds)
                    }
                )
                guard generation == currentGeneration, !Task.isCancelled else { return }
                try await open(
                    credentials: credentials,
                    localNotificationsEnabled: localNotificationsEnabled,
                    onStoresReady: onStoresReady,
                    onClosed: onClosed,
                    onRetryWaiting: onRetryWaiting
                )
            } catch is CancellationError {
                return
            } catch let error as AuthError {
                guard generation == currentGeneration else { return }
                onFailure(error)
            } catch {
                guard generation == currentGeneration else { return }
                onFailure(.transport(error.localizedDescription))
            }
        }
    }

    func close() async {
        generation &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        let currentRPC = rpc
        rpc = nil
        await currentRPC?.close()
    }

    private func open(
        credentials: AuthCredentials,
        localNotificationsEnabled: Bool,
        onStoresReady: @escaping @MainActor (Stores, RPCClient) -> Void,
        onClosed: @escaping @MainActor (RPCClient, Int) async -> Void,
        onRetryWaiting: @escaping @MainActor (TimeInterval) -> Void
    ) async throws {
        guard let url = URL(string: "ws://\(host):\(port)/v1/ws") else {
            throw AuthError.invalidURL
        }
        let ws = WSClient(
            url: url,
            headers: [
                "Sec-WebSocket-Protocol": "cmuxremote.v1",
                "Authorization": "Bearer \(credentials.bearer)",
            ],
            beforeReconnect: { [auth, onRetryWaiting] in
                do {
                    _ = try await auth.validateStoredCredentials()
                } catch {
                    if RelayCredentialRetrier.isRetryable(error) {
                        await onRetryWaiting(5)
                    }
                    throw error
                }
            }
        )
        let rpc = RPCClient(transport: ws)
        let stores = Stores(
            workspace: WorkspaceStore(rpc: rpc),
            surface: SurfaceStore(rpc: rpc),
            hostStatus: HostStatusStore(rpc: rpc)
        )
        stores.workspace.onWorkspaceAlert = {
            self.notificationStore.append($0, deliveryPolicy: .userInputRequired)
        }
        self.rpc = rpc
        onStoresReady(stores, rpc)

        await rpc.onPush { [weak self] frame in
            Task { @MainActor in
                stores.surface.ingest(frame)
                self?.notificationStore.ingest(frame)
            }
        }
        await ws.setOnText { text in Task { await rpc.handleIncoming(text: text) } }
        await ws.setOnClose { code in
            Task { @MainActor in await onClosed(rpc, code) }
        }
        await ws.setOnOpen { [weak self] in
            guard let self else { return }
            await Self.runOpenSequence(
                rpc: rpc,
                stores: stores,
                credentials: credentials,
                host: host,
                remoteFiles: remoteFiles
            )
        }
        notificationRegistrar.configure(authClient: auth)
        if localNotificationsEnabled {
            await notificationRegistrar.registerForRemoteNotifications()
        }
        await ws.connect()
    }

    static func runOpenSequence(
        sendHello: @MainActor () async -> Void,
        initializeRemoteFiles: @MainActor () async -> Void,
        resubscribeSurface: @MainActor () async -> Void,
        refreshWorkspace: @MainActor () async -> Void,
        refreshHost: @MainActor () async -> Void
    ) async {
        await sendHello()
        await initializeRemoteFiles()
        await resubscribeSurface()
        await refreshWorkspace()
        await refreshHost()
    }

    private static func runOpenSequence(
        rpc: RPCClient,
        stores: Stores,
        credentials: AuthCredentials,
        host: String,
        remoteFiles: RemoteFileFeatureCoordinator
    ) async {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        await runOpenSequence(
            sendHello: {
                let hello = HelloFrame(
                    deviceId: credentials.deviceId,
                    appVersion: version,
                    protocolVersion: 1
                )
                if let data = try? SharedKitJSON.deterministicEncoder.encode(hello),
                   let text = String(data: data, encoding: .utf8) {
                    await rpc.sendRaw(text: text)
                }
            },
            initializeRemoteFiles: {
                await remoteFiles.connect(
                    rpc: rpc,
                    hostID: host,
                    accountScope: credentials.deviceId
                )
            },
            resubscribeSurface: { await stores.surface.resubscribe() },
            refreshWorkspace: { await stores.workspace.refresh() },
            refreshHost: { await stores.hostStatus.refreshBattery() }
        )
    }
}
