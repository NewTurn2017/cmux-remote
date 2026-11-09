import Foundation

/// `update/config.json`: the install record `install-launchd.sh` writes.
///
/// Internal stable interface shared with `scripts/install-launchd.sh` and `scripts/relay-update.sh`.
/// The file also carries `origin`, `check_interval_seconds`, `idle_restart_seconds`, and
/// `installed_version`, which only the scripts read.
struct RelayUpdateConfigFile: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var autoUpdate: Bool
}
