import Foundation

/// `update/state.json`: the updater's progress, written only by `scripts/relay-update.sh`.
///
/// Internal stable interface. `state` and `last_error_code` use the `RelayUpdateState` and
/// `RelayUpdateFailureCode` wire values; `pid` is the updater process while it works; `signing` is
/// `identity` or `adhoc`. Updater-only keys, such as `next_check_at_ms`, are ignored here.
struct RelayUpdateStateFile: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var state: String
    var pid: Int32?
    var latestVersion: String?
    var lastCheckedAtMs: Int64?
    var lastErrorCode: String?
    var signing: String?
}
