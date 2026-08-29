import Foundation

/// Defines cadence, retry, and collection bounds for one surface render hub.
public struct SurfaceRenderHubConfiguration: Equatable, Sendable {
    /// Configured interactive frame rate.
    public let activeFps: Int

    /// Configured quiescent frame rate.
    public let idleFps: Int

    /// Inactivity interval after which the hub selects ``SurfaceRenderCadence/idle``.
    public let idleAfter: TimeInterval

    /// Maximum scheduler delay after repeated source failures.
    public let maximumErrorBackoff: TimeInterval

    /// Maximum simultaneous subscribers accepted by one surface.
    public let maximumSubscribers: Int

    /// Creates bounded scheduler configuration.
    ///
    /// Nonpositive frame rates and collection bounds are normalized to one. Retry delay is
    /// never allowed below the slowest configured cadence interval.
    ///
    /// - Parameters:
    ///   - activeFps: Interactive target, normally the server's configured 15 Hz.
    ///   - idleFps: Quiescent target, normally the server's configured 5 Hz.
    ///   - idleAfter: Seconds without input or changed render revisions before idling.
    ///   - maximumErrorBackoff: Upper bound for exponential source-error backoff.
    ///   - maximumSubscribers: Hard subscriber bound for one surface.
    public init(
        activeFps: Int,
        idleFps: Int,
        idleAfter: TimeInterval = 1.5,
        maximumErrorBackoff: TimeInterval = 2,
        maximumSubscribers: Int = 64
    ) {
        self.activeFps = max(1, activeFps)
        self.idleFps = max(1, idleFps)
        self.idleAfter = max(0, idleAfter)
        self.maximumErrorBackoff = max(
            1 / Double(max(1, idleFps)),
            maximumErrorBackoff
        )
        self.maximumSubscribers = max(1, maximumSubscribers)
    }
}
