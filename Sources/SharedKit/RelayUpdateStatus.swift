import Foundation

/// The relay's self-update status: `update` in `relay.info` and the result of `relay.update.start`.
public struct RelayUpdateStatus: Codable, Sendable, Equatable {
    /// Whether auto-update is turned on for this relay install.
    public var autoUpdateEnabled: Bool
    /// Current update progress.
    public var state: RelayUpdateState
    /// Newest release version seen by the last check, such as `2.0.1`.
    public var latestVersion: String?
    /// When the last release check finished, in milliseconds since 1970.
    public var lastCheckedAt: Int64?
    /// Why the last attempt failed.
    public var lastErrorCode: RelayUpdateFailureCode?
    /// `true` while staged or applying, when the relay restarts soon; otherwise `nil` and omitted.
    public var restartPending: Bool?
    /// `true` when the relay is ad-hoc signed, so macOS may ask for Downloads access again; otherwise `nil` and omitted.
    public var adhocSigning: Bool?

    /// Creates an update status. `false` flags are stored as `nil` so they stay off the wire.
    public init(
        autoUpdateEnabled: Bool,
        state: RelayUpdateState,
        latestVersion: String? = nil,
        lastCheckedAt: Int64? = nil,
        lastErrorCode: RelayUpdateFailureCode? = nil,
        restartPending: Bool? = nil,
        adhocSigning: Bool? = nil
    ) {
        self.autoUpdateEnabled = autoUpdateEnabled
        self.state = state
        self.latestVersion = latestVersion
        self.lastCheckedAt = lastCheckedAt
        self.lastErrorCode = lastErrorCode
        self.restartPending = restartPending == true ? true : nil
        self.adhocSigning = adhocSigning == true ? true : nil
    }

    /// Decodes and validates an update status, keeping unknown states and failure codes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            autoUpdateEnabled: try c.contractRequired(Bool.self, .autoUpdateEnabled, field: "auto_update_enabled"),
            state: try c.contractRequired(RelayUpdateState.self, .state, field: "state"),
            latestVersion: try c.contractOptionalText(.latestVersion, field: "latest_version"),
            lastCheckedAt: try c.contractOptional(Int64.self, .lastCheckedAt, field: "last_checked_at"),
            lastErrorCode: try c.contractOptional(RelayUpdateFailureCode.self, .lastErrorCode, field: "last_error_code"),
            restartPending: try c.contractOptional(Bool.self, .restartPending, field: "restart_pending"),
            adhocSigning: try c.contractOptional(Bool.self, .adhocSigning, field: "adhoc_signing")
        )
    }

    private enum CodingKeys: String, CodingKey {
        case autoUpdateEnabled, state, latestVersion, lastCheckedAt, lastErrorCode, restartPending, adhocSigning
    }
}
