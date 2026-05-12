import Foundation
import ArgumentParser
import NIOPosix
import RelayCore
import CMUXClient
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
        abstract: "Run the HTTP + WebSocket relay."
    )

    @Option(name: .customLong("config"),
            help: "Path to relay.json (default: ~/.cmuxremote/relay.json).")
    var config: String = defaultConfigPath()

    func run() async throws {
        let logger = Logger(label: "cmux-relay")
        let store = ConfigStore(url: URL(fileURLWithPath: config))
        try store.reload()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let conn = CmuxConnection(socketPath: cmuxSocketPath(), group: group)
        let facade = CMUXFacadeImpl(connection: conn)
        let reader = CmuxSurfaceReader(connection: conn)
        let manager = SessionManager(reader: reader,
                                     defaultFps: store.current.defaultFps,
                                     idleFps: store.current.idleFps)
        conn.onReset = {
            Task { await manager.broadcastReset() }
        }
        let deviceStore = try DeviceStore(url: URL(fileURLWithPath: devicesStorePath()))
        let auth = TailscaledLocalAuth()
        let routes = Routes(deviceStore: deviceStore,
                            config: store.current,
                            auth: auth)
        let server = HTTPServer(group: group, routes: routes, auth: auth,
                                deviceStore: deviceStore,
                                sessionManager: manager,
                                cmux: facade)

        let (host, port) = parseListen(store.current.listen)

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

        logger.info("starting cmux-relay on \(host):\(port)")
        try await server.run(host: host, port: port)
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
