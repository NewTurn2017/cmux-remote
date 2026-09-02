import Foundation
import RelayCore

final class MutableRelayConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RelayConfig

    init(_ value: RelayConfig) {
        self.value = value
    }

    func snapshot() -> RelayConfig {
        lock.withLock { value }
    }

    func setAllowLogin(_ logins: [String]) {
        lock.withLock { value.allowLogin = logins }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
