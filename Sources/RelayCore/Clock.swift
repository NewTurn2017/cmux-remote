import Foundation

public protocol Clock: Sendable {
    var now: TimeInterval { get }
}

public final class SystemClock: Clock {
    public init() {}
    public var now: TimeInterval { Date().timeIntervalSince1970 }
}

public final class FakeClock: Clock, @unchecked Sendable {
    private var t: TimeInterval = 0
    public init() {}
    public var now: TimeInterval { t }
    public func advance(by dt: TimeInterval) { t += dt }
}
