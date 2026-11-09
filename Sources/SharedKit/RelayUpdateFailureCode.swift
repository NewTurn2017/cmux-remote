import Foundation

/// Why the relay's last self-update attempt failed. The relay sends codes only, never messages or paths.
///
/// A code unknown to this client decodes as ``unknown(_:)`` and re-encodes unchanged.
public enum RelayUpdateFailureCode: Sendable, Equatable, Codable {
    /// The release tag list or source could not be fetched.
    case networkFailed
    /// The release tag did not match its commit, or is not on the main branch.
    case tagVerificationFailed
    /// The new relay did not build.
    case buildFailed
    /// The built relay reported a version other than its release tag.
    case versionMismatch
    /// The new relay could not be signed with the remembered identity.
    case signFailed
    /// Installing the new relay failed; the previous relay was restored.
    case installFailed
    /// The new relay did not stay running; the previous relay was restored.
    case startFailed
    /// The Mac does not have enough free disk space to build.
    case insufficientDisk
    /// The Mac has no usable Swift toolchain or git.
    case toolchainMissing
    /// The installed relay's version could not be read.
    case versionUnknown
    /// The update stopped before it finished, for example on logout or shutdown.
    case interrupted
    /// A code unknown to this client version.
    case unknown(String)

    /// The snake_case code sent on the wire.
    public var rawValue: String {
        switch self {
        case .networkFailed: return "network_failed"
        case .tagVerificationFailed: return "tag_verification_failed"
        case .buildFailed: return "build_failed"
        case .versionMismatch: return "version_mismatch"
        case .signFailed: return "sign_failed"
        case .installFailed: return "install_failed"
        case .startFailed: return "start_failed"
        case .insufficientDisk: return "insufficient_disk"
        case .toolchainMissing: return "toolchain_missing"
        case .versionUnknown: return "version_unknown"
        case .interrupted: return "interrupted"
        case .unknown(let rawValue): return rawValue
        }
    }

    /// Maps a wire code to a known failure, keeping unknown codes.
    ///
    /// - Parameter rawValue: The wire code.
    public init(rawValue: String) {
        switch rawValue {
        case "network_failed": self = .networkFailed
        case "tag_verification_failed": self = .tagVerificationFailed
        case "build_failed": self = .buildFailed
        case "version_mismatch": self = .versionMismatch
        case "sign_failed": self = .signFailed
        case "install_failed": self = .installFailed
        case "start_failed": self = .startFailed
        case "insufficient_disk": self = .insufficientDisk
        case "toolchain_missing": self = .toolchainMissing
        case "version_unknown": self = .versionUnknown
        case "interrupted": self = .interrupted
        default: self = .unknown(rawValue)
        }
    }

    /// Decodes a failure code from its wire string.
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    /// Encodes the failure code as its wire string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
