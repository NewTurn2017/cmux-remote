import Foundation

/// Captures bounded, monotonic counters for one render-hub lifetime.
public struct SurfaceRenderHubMetrics: Equatable, Sendable {
    /// Number of source reads started.
    public internal(set) var readAttempts = 0

    /// Number of updated source outcomes accepted.
    public internal(set) var updatedOutcomes = 0

    /// Number of unchanged source outcomes skipped before diff or checksum work.
    public internal(set) var unchangedOutcomes = 0

    /// Number of stale or malformed source outcomes ignored without changing state.
    public internal(set) var ignoredOutcomes = 0

    /// Number of source and lifecycle release errors observed.
    public internal(set) var errors = 0

    /// Number of callback deliveries made to active subscribers.
    public internal(set) var fanoutDeliveries = 0

    /// Highest observed number of simultaneous source reads.
    public internal(set) var maximumInFlightReads = 0

    /// Number of busy ticks folded into the single pending continuation.
    public internal(set) var coalescedTicks = 0

    /// Number of source continuity releases attempted.
    public internal(set) var releaseAttempts = 0

    /// Creates zeroed metrics for a new hub lifetime.
    public init() {}
}
