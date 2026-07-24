import Foundation
import ArgumentParser
import NIOPosix
import RelayCore
import CMUXClient
import SharedKit
import Logging

/// `cmux-relay` CLI entry point. Spec section 6.4, plan task 12.
///
/// Subcommands:
/// - `serve` (default) — boot the HTTP/WS relay against the local cmux UDS.
/// - `devices list` / `devices revoke <id>` — inspect / mutate
///   `~/.cmuxremote/devices.json` without going through the running server.
///
/// The AppKit menu-bar subcommand from the plan is intentionally deferred
/// — it's not on the critical path to "phone talks to relay" and adds
/// linker weight that the v1.0 service binary doesn't need.
@main
struct CmuxRelay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cmux-relay",
        subcommands: [Serve.self, Devices.self],
        defaultSubcommand: Serve.self
    )
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the configured direct and/or broker relay transports."
    )

    @Option(name: .customLong("config"),
            help: "Path to relay.json (default: ~/.cmuxremote/relay.json).")
    var config: String = defaultConfigPath()

    func run() async throws {
        let logger = Logger(label: "cmux-relay")
        let store = ConfigStore(url: URL(fileURLWithPath: config))
        try store.reload()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let conn = CmuxConnection(group: group)
        let facade = CMUXFacadeImpl(connection: conn)
        let historyFacade = CMUXFacadeImpl(connection: conn, lane: .history)
        let history = SurfaceHistoryService(cmux: historyFacade)
        let reader = CmuxSurfaceReader(connection: conn)
        let manager = SessionManager(reader: reader,
                                     defaultFps: store.current.defaultFps,
                                     idleFps: store.current.idleFps)
        let deviceStore = try DeviceStore(url: URL(fileURLWithPath: devicesStorePath()))
        let apnsProvider = APNsProviderClient(config: { store.current.apns })
        let apnsFanout = InboxPushFanout(
            deviceStore: deviceStore,
            sender: apnsProvider,
            config: { store.current.apns }
        )
        conn.onReset = {
            Task { await manager.broadcastReset() }
        }
        Task {
            var policy = ReconnectPolicy()
            while !Task.isCancelled {
                do {
                    let client = try await conn.connectForEvents()
                    let stream = EventStream(client: client) { event in
                        if event.category == .system,
                           let boot = try? event.payload.decode(BootInfo.self)
                        {
                            conn.observe(bootInfo: boot)
                        }
                        Task { await manager.broadcastToAll(frame: .event(event)) }
                        Task { await apnsFanout.deliver(event: event) }
                    }
                    await stream.start(categories: EventCategory.allCases)
                    logger.info("cmux event stream attached")
                    let attachedAt = ContinuousClock.now
                    await client.awaitClosed()
                    // Only treat this as a healthy connection (and reset backoff)
                    // if it stayed attached a while; otherwise a flapping/crash-
                    // looping cmux would be re-attacked every base interval.
                    if ContinuousClock.now - attachedAt > .seconds(5) {
                        policy.reset()
                    }
                    logger.warning("cmux event stream detached; will re-attach")
                    await conn.invalidateEvents()
                } catch {
                    logger.warning("cmux event stream unavailable: \(String(describing: error))")
                }
                let delay = policy.nextDelay()
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        let sighup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
        sighup.setEventHandler {
            do {
                try store.reload()
                logger.info("config reloaded")
            } catch {
                logger.warning("config reload failed: \(error)")
            }
        }
        sighup.resume()
        signal(SIGHUP, SIG_IGN)

        var brokerRunner: Task<Void, Never>?
        if store.current.transport.enablesBroker {
            guard let brokerConfig = store.current.broker else {
                throw ValidationError("transport '\(store.current.transport.rawValue)' requires a broker block")
            }
            guard !brokerConfig.relayToken.isEmpty else {
                throw ValidationError("broker.relay_token must not be empty")
            }
            let tunnel = try BrokerTunnelClient(config: brokerConfig)
            let bridge = RemoteSessionBridge(sessionManager: manager, cmux: facade, history: history) { envelope in
                await tunnel.send(envelope)
            }
            await tunnel.setOnEnvelope { envelope in
                await bridge.receive(envelope)
            }
            await tunnel.setOnDisconnect {
                await bridge.disconnectAll()
            }
            brokerRunner = Task { await tunnel.runForever() }
            logger.info("broker transport enabled for relay_id=\(brokerConfig.relayId)")
        }
        defer { brokerRunner?.cancel() }

        if store.current.transport.enablesDirect {
            let auth = TailscaledLocalAuth()

            // A fresh direct-mode config has an empty allow_login. Authorise
            // this Mac's own tailnet login unless the operator opts out.
            var effectiveConfig = store.current
            if ProcessInfo.processInfo.environment["CMUX_NO_SELF_LOGIN"] == nil,
               let selfLogin = await auth.selfLogin() {
                if !effectiveConfig.allowLogin.contains(selfLogin) {
                    logger.info("auto-authorising this Mac's tailnet login for pairing: \(selfLogin)")
                }
                effectiveConfig = effectiveConfig.authorizing(login: selfLogin)
            }

            let routes = Routes(deviceStore: deviceStore,
                                config: effectiveConfig,
                                auth: auth)
            let server = HTTPServer(group: group, routes: routes, auth: auth,
                                    deviceStore: deviceStore,
                                    sessionManager: manager,
                                    cmux: facade,
                                    history: history)
            let (host, port) = parseListen(store.current.listen)
            logger.info("direct transport listening on \(host):\(port)")
            try await server.run(host: host, port: port)
        } else if let brokerRunner {
            await brokerRunner.value
        }
    }
}

struct Devices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "Inspect and revoke registered phones.",
        subcommands: [List.self, Revoke.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Print all registered devices."
        )

        func run() async throws {
            let store = try DeviceStore(url: URL(fileURLWithPath: devicesStorePath()))
            for d in store.allDevices() {
                print("\(d.deviceId)  \(d.loginName)  \(d.hostname)  registered=\(d.registeredAt)")
            }
        }
    }

    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "revoke",
            abstract: "Revoke a single device by id."
        )

        @Argument(help: "Device id to revoke.")
        var deviceId: String

        func run() async throws {
            let store = try DeviceStore(url: URL(fileURLWithPath: devicesStorePath()))
            try store.revoke(deviceId: deviceId)
            print("revoked \(deviceId)")
        }
    }
}

// MARK: - Path helpers

func defaultConfigPath() -> String {
    "\(NSHomeDirectory())/.cmuxremote/relay.json"
}

func devicesStorePath() -> String {
    "\(NSHomeDirectory())/.cmuxremote/devices.json"
}

/// Split `RelayConfig.listen` ("host:port") into a host + port pair.
/// Falls back to 4399 if the port is missing or unparseable so a typo
/// in relay.json doesn't take the daemon down silently.
func parseListen(_ listen: String) -> (host: String, port: Int) {
    let parts = listen.split(separator: ":", maxSplits: 1).map(String.init)
    let host = parts.first ?? "0.0.0.0"
    let port = parts.count >= 2 ? (Int(parts[1]) ?? 4399) : 4399
    return (host, port)
}
