import Foundation

/// Reports whether a terminal read produced new work for downstream rendering.
public enum CMUXTerminalReadOutcome: Equatable, Sendable {
    /// A new authoritative screen is available.
    case updated(CMUXTerminalReadUpdate)

    /// The replay matches the already accepted epoch and revision exactly.
    case unchanged(CMUXTerminalReplayIdentity)

    /// A valid but stale replay was ignored.
    case ignored(CMUXTerminalReplayIgnoreReason)
}
