import Foundation

/// Production monotonic clock used by surface render schedulers.
public struct ContinuousSurfaceRenderClock: SurfaceRenderClock {
    /// Creates a production render clock.
    public init() {}

    /// Returns system uptime so wall-clock changes cannot alter cadence state.
    public var now: TimeInterval {
        get async { ProcessInfo.processInfo.systemUptime }
    }

    /// Suspends for the requested cadence interval with cooperative cancellation.
    ///
    /// - Parameter seconds: Number of seconds to suspend.
    /// - Throws: `CancellationError` when the owning scheduler is cancelled.
    public func sleep(for seconds: TimeInterval) async throws {
        // This is the intended, bounded render cadence; lifecycle cancellation stops it.
        try await ContinuousClock().sleep(for: .seconds(max(0, seconds)))
    }
}
