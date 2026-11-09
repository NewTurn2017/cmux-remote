import SharedKit

enum BrowserRefreshPolicy {
    static let defaultIntervalSeconds = Double(SurfaceBrowserCaptureLimits.recommendedRefreshSeconds)
    static let maxBackoffSeconds: Double = 30

    /// Delay before the next automatic capture, measured from the end of the previous one.
    /// Failures double the base interval up to `maxBackoffSeconds` (never below the base).
    static func delaySeconds(consecutiveFailures: Int, baseSeconds: Double = defaultIntervalSeconds) -> Double {
        guard consecutiveFailures > 0 else { return baseSeconds }
        let doubled = baseSeconds * Double(1 << min(consecutiveFailures, 16))
        return min(doubled, max(maxBackoffSeconds, baseSeconds))
    }
}
