import Foundation

/// `update/relay-runtime.json`: the running relay's identity and phone connections.
///
/// Internal stable interface. Updaters from earlier releases read this file from newer relays, so
/// field meanings never change: `pid` and `version` identify the relay that is listening (the
/// updater's health check), `active_sessions` counts attached phones, and `zero_since_ms` is when
/// that count last became zero (absent while a phone is attached).
struct RelayRuntimeFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var pid: Int32
    var version: String
    var startedAtMs: Int64
    var activeSessions: Int
    var zeroSinceMs: Int64?
}
