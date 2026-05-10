import Foundation

/// Per-device sliding-window frame budget.
///
/// Actor-isolated so the WS handler (which calls `consumeFrame()` on the NIO
/// event loop) and any future supervisor (e.g. SessionManager broadcasting
/// resets) cannot race on the `stamps` array.
public actor DeviceFpsBudget {
    public nonisolated let maxPerSecond: Int
    private let clock: Clock
    private var stamps: [TimeInterval] = []

    public init(maxPerSecond: Int, clock: Clock = SystemClock()) {
        self.maxPerSecond = maxPerSecond
        self.clock = clock
    }

    public func consumeFrame() -> Bool {
        let now = clock.now
        stamps.removeAll { now - $0 > 1.0 }
        guard stamps.count < maxPerSecond else { return false }
        stamps.append(now)
        return true
    }
}
