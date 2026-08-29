import Foundation

/// Explains why a valid replay snapshot was intentionally not converted to a screen.
public enum CMUXTerminalReplayIgnoreReason: Equatable, Sendable {
    /// The replay revision is older than the accepted revision in the same epoch.
    case staleRevision(received: UInt64, current: UInt64)

    /// The replay belongs to an epoch already superseded by a newer producer lifetime.
    case retiredEpoch(String)
}
