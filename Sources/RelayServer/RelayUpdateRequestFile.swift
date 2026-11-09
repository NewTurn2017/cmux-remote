import Foundation

/// `update/request.json`: a user's `relay.update.start`, written only by the relay.
///
/// Internal stable interface. The updater checks and applies right away while this file exists,
/// whatever its check schedule or the phone connections, then deletes it.
struct RelayUpdateRequestFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var source: String
    var requestedAtMs: Int64
}
