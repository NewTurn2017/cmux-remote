import Foundation

/// Files the relay and its updater job exchange under the relay home.
///
/// Internal stable interface: `scripts/relay-update.sh` and `scripts/install-launchd.sh` from every
/// release use these exact paths, so they must not move.
struct RelayUpdatePaths: Sendable, Equatable {
    /// The updater job's launchd label.
    static let updaterLabel = "com.genie.cmuxremote.updater"

    /// The relay home, normally `~/.cmuxremote`.
    let home: URL

    var updateDirectory: URL { home.appendingPathComponent("update", isDirectory: true) }
    /// Written by `install-launchd.sh`; read by the relay and the updater.
    var configFile: URL { updateDirectory.appendingPathComponent("config.json") }
    /// Written only by the updater.
    var stateFile: URL { updateDirectory.appendingPathComponent("state.json") }
    /// Written only by the relay for `relay.update.start`; consumed by the updater.
    var requestFile: URL { updateDirectory.appendingPathComponent("request.json") }
    /// Written only by the relay; the updater reads it to decide when to restart and to check health.
    var runtimeFile: URL { updateDirectory.appendingPathComponent("relay-runtime.json") }

    /// The relay home from `CMUX_REMOTE_HOME`, which the installed launchd plist sets.
    ///
    /// Without it the relay is a development run and leaves an installed relay's update files alone.
    static func fromEnvironment(_ environment: [String: String]) -> RelayUpdatePaths? {
        guard let home = environment["CMUX_REMOTE_HOME"], !home.isEmpty else { return nil }
        return RelayUpdatePaths(home: URL(fileURLWithPath: home, isDirectory: true))
    }
}
