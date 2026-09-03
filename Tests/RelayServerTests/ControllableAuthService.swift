import Foundation
import RelayCore

final class ControllableAuthService: AuthService, @unchecked Sendable {
    private let lock = NSLock()
    private var peerResult: Result<PeerIdentity, Error>
    private var ownerResult: Result<String?, Error>
    private var ownerCalls = 0
    private var peerCalls = 0

    init(
        peer: PeerIdentity = .init(
            loginName: "owner@example.com",
            hostname: "iPhone",
            os: "iOS",
            nodeKey: "nodekey:test"
        ),
        selfLogin: Result<String?, Error> = .success("owner@example.com")
    ) {
        peerResult = .success(peer)
        ownerResult = selfLogin
    }

    func whois(remoteAddr: String) async throws -> PeerIdentity {
        try lock.withLock {
            peerCalls += 1
            return try peerResult.get()
        }
    }

    func selfLogin() async throws -> String? {
        try lock.withLock {
            ownerCalls += 1
            return try ownerResult.get()
        }
    }

    func setSelfLogin(_ result: Result<String?, Error>) {
        lock.withLock { ownerResult = result }
    }

    func setPeer(_ result: Result<PeerIdentity, Error>) {
        lock.withLock { peerResult = result }
    }

    func selfLoginCallCount() -> Int {
        lock.withLock { ownerCalls }
    }

    func peerCallCount() -> Int {
        lock.withLock { peerCalls }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
