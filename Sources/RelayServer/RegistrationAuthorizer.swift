import Foundation
import RelayCore

/// Request-time authorization for relay registration.
///
/// Explicit `allow_login` entries are always authoritative. Automatic owner
/// authorization compares the peer login with the Mac's live Tailscale login.
/// The result cache includes failures, and the in-flight task coalesces bursts,
/// so one degraded Tailscale client cannot spawn one CLI process per request.
actor RegistrationAuthorizer {
    enum Decision: Equatable, Sendable {
        case allowed
        case denied
        case identityUnavailable
    }

    private enum OwnerIdentity: Equatable, Sendable {
        case login(String)
        case taggedNode
        case unavailable
    }

    private struct Cache: Sendable {
        let identity: OwnerIdentity
        let expiresAt: TimeInterval
    }

    private let auth: any AuthService
    private let config: @Sendable () -> RelayConfig
    private let allowSelfLogin: Bool
    private let clock: any Clock
    private let cacheDuration: TimeInterval
    private var cache: Cache?
    private var inFlight: Task<OwnerIdentity, Never>?

    init(
        auth: any AuthService,
        config: @escaping @Sendable () -> RelayConfig,
        allowSelfLogin: Bool,
        clock: any Clock = SystemClock(),
        cacheDuration: TimeInterval = 5
    ) {
        self.auth = auth
        self.config = config
        self.allowSelfLogin = allowSelfLogin
        self.clock = clock
        self.cacheDuration = cacheDuration
    }

    func decision(for login: String) async -> Decision {
        if config().allowLogin.contains(login) { return .allowed }
        guard allowSelfLogin else { return .denied }

        switch await ownerIdentity() {
        case .login(login): return .allowed
        case .login, .taggedNode: return .denied
        case .unavailable: return .identityUnavailable
        }
    }

    func invalidateCache() {
        cache = nil
    }

    private func ownerIdentity() async -> OwnerIdentity {
        let now = clock.now
        if let cache, now < cache.expiresAt { return cache.identity }
        if let inFlight { return await inFlight.value }

        let auth = auth
        let task = Task<OwnerIdentity, Never> {
            do {
                if let login = try await auth.selfLogin() {
                    return .login(login)
                }
                return .taggedNode
            } catch {
                return .unavailable
            }
        }
        inFlight = task
        let identity = await task.value
        cache = Cache(identity: identity, expiresAt: clock.now + cacheDuration)
        inFlight = nil
        return identity
    }
}
