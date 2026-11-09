import Foundation

/// Result of `relay.info`: the relay version and its self-update status.
public struct RelayInfoResult: Codable, Sendable, Equatable {
    /// The relay's ``CmuxRemoteVersion/marketing`` version, such as `2.0.0`.
    public var version: String
    /// Self-update status. Relays from 2.0.0 always send it.
    public var update: RelayUpdateStatus?

    /// Creates a relay-info result.
    public init(version: String, update: RelayUpdateStatus? = nil) {
        self.version = version
        self.update = update
    }

    /// Decodes and validates a relay-info result.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.contractText(.version, field: "version")
        update = try c.contractOptional(RelayUpdateStatus.self, .update, field: "update")
    }

    private enum CodingKeys: String, CodingKey {
        case version, update
    }
}
