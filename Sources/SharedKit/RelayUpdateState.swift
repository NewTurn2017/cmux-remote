import Foundation

/// Progress of the relay's self-update, reported by `relay.info` and `relay.update.start`.
///
/// A state unknown to this client decodes as ``unknown(_:)`` and re-encodes unchanged.
public enum RelayUpdateState: Sendable, Equatable, Codable {
    /// Nothing to do; up to date when `latest_version` equals the relay version.
    case idle
    /// Checking the origin for a newer release tag.
    case checking
    /// Fetching the release source.
    case downloading
    /// Building and signing the new relay.
    case building
    /// Built; the relay restarts once no phone is connected.
    case staged
    /// Replacing the relay and restarting it; the connection drops next.
    case applying
    /// The last attempt failed; see `last_error_code`.
    case failed
    /// Auto-update is turned off on the Mac.
    case disabled
    /// This relay install cannot update itself.
    case unavailable
    /// A state unknown to this client version.
    case unknown(String)

    /// The snake_case value sent on the wire.
    public var rawValue: String {
        switch self {
        case .idle: return "idle"
        case .checking: return "checking"
        case .downloading: return "downloading"
        case .building: return "building"
        case .staged: return "staged"
        case .applying: return "applying"
        case .failed: return "failed"
        case .disabled: return "disabled"
        case .unavailable: return "unavailable"
        case .unknown(let rawValue): return rawValue
        }
    }

    /// Maps a wire value to a known state, keeping unknown values.
    ///
    /// - Parameter rawValue: The wire value.
    public init(rawValue: String) {
        switch rawValue {
        case "idle": self = .idle
        case "checking": self = .checking
        case "downloading": self = .downloading
        case "building": self = .building
        case "staged": self = .staged
        case "applying": self = .applying
        case "failed": self = .failed
        case "disabled": self = .disabled
        case "unavailable": self = .unavailable
        default: self = .unknown(rawValue)
        }
    }

    /// Decodes a state from its wire string.
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    /// Encodes the state as its wire string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
