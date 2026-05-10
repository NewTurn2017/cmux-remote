import Foundation

/// Per-device sliding-window rate limiter. Spec section 7.2.
///
/// Buckets are keyed by `(deviceId, method)`. Caps:
/// - `surface.send_text`: 100/s
/// - `surface.send_key`:  200/s
/// - everything else: unlimited (cap is enforced in the relay's other layers
///   — DiffEngine fps cap, polling cadence, etc.)
///
/// Mutations serialise through an `NSLock`; tests cover concurrent device
/// IDs trivially. Actor conversion is deferred — the lock is fast enough on
/// the WS hot path and avoids forcing every `allow()` call to `await`.
public final class PerDeviceRateLimiter: @unchecked Sendable {
    private let clock: Clock
    private var stamps: [String: [TimeInterval]] = [:]
    private let lock = NSLock()

    public init(clock: Clock = SystemClock()) { self.clock = clock }

    public func allow(deviceId: String, method: String) -> Bool {
        let cap: Int
        switch method {
        case "surface.send_text": cap = 100
        case "surface.send_key":  cap = 200
        default: return true
        }
        lock.lock(); defer { lock.unlock() }
        let key = "\(deviceId)|\(method)"
        let now = clock.now
        var arr = stamps[key, default: []]
        arr.removeAll { now - $0 > 1.0 }
        guard arr.count < cap else { stamps[key] = arr; return false }
        arr.append(now); stamps[key] = arr; return true
    }
}
