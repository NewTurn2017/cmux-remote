import Foundation
import RelayCore

/// Coalesces and briefly caches Tailscale `whois` results by source address.
/// Anonymous register requests therefore cannot create one CLI process per
/// retry while the Tailscale GUI or network extension is recovering.
actor RegistrationPeerResolver {
    enum Result: Sendable {
        case peer(PeerIdentity)
        case peerNotFound
        case unavailable
    }

    private struct CacheEntry: Sendable {
        let result: Result
        let expiresAt: TimeInterval
    }

    private let auth: any AuthService
    private let clock: any Clock
    private let cacheDuration: TimeInterval
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<Result, Never>] = [:]

    init(
        auth: any AuthService,
        clock: any Clock = SystemClock(),
        cacheDuration: TimeInterval = 5
    ) {
        self.auth = auth
        self.clock = clock
        self.cacheDuration = cacheDuration
    }

    func resolve(remoteAddress: String) async -> Result {
        let now = clock.now
        if let entry = cache[remoteAddress], now < entry.expiresAt {
            return entry.result
        }
        if let task = inFlight[remoteAddress] {
            return await task.value
        }

        let auth = auth
        let task = Task<Result, Never> {
            do {
                return .peer(try await auth.whois(remoteAddr: remoteAddress))
            } catch TailnetIdentityError.peerNotFound {
                return .peerNotFound
            } catch {
                return .unavailable
            }
        }
        inFlight[remoteAddress] = task
        let result = await task.value
        cache[remoteAddress] = CacheEntry(
            result: result,
            expiresAt: clock.now + cacheDuration
        )
        inFlight[remoteAddress] = nil
        return result
    }
}
