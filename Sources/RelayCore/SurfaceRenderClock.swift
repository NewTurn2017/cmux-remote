import Foundation

/// Supplies monotonic time and cancellable cadence suspension to a surface render hub.
public protocol SurfaceRenderClock: Sendable {
    /// Returns the current monotonic time in seconds.
    var now: TimeInterval { get async }

    /// Suspends for an intended render cadence or bounded retry delay.
    ///
    /// - Parameter seconds: Number of seconds to suspend.
    /// - Throws: `CancellationError` when the hub lifecycle ends.
    func sleep(for seconds: TimeInterval) async throws
}
