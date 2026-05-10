import Foundation

public final class DeviceFpsBudget: @unchecked Sendable {
    public let maxPerSecond: Int
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
