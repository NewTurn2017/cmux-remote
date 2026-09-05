import Foundation
import Logging
import NIOCore
import NIOHTTP1
import Crypto
import RelayCore
import SharedKit

/// Lightweight response envelope. The HTTP layer in M3.11 will translate
/// this into NIOHTTP1 head + body chunks; keeping it small here makes
/// `Routes` independent of the channel pipeline.
public struct HTTPResponseLite: Sendable {
    public var status: HTTPResponseStatus
    public var body: Data?
    /// Emitted as `Content-Type` when non-nil. The JSON API leaves it nil —
    /// its clients decode by contract, and adding the header there would be a
    /// behaviour change to the shipped iOS app. Static files must set it or
    /// the browser refuses to run the script it just downloaded.
    public var contentType: String?
    /// Emitted as `Cache-Control` when non-nil. Static files set it because a
    /// browser left to its own devices will keep serving a stale `index.html`
    /// after the file on disk changed — which reads as "my fix didn't deploy"
    /// and costs a debugging round trip.
    public var cacheControl: String?
    public init(_ status: HTTPResponseStatus,
                body: Data? = nil,
                contentType: String? = nil,
                cacheControl: String? = nil)
    {
        self.status = status; self.body = body
        self.contentType = contentType; self.cacheControl = cacheControl
    }
}

/// HTTP REST endpoints. Spec section 6.1.
///
/// Actor-isolated because authenticated paths (`apns`, `revoke`) and the
/// register flow can race with `ConfigStore.reload` and the WS handler.
/// The DeviceStore + AuthService it depends on are themselves
/// thread-safe, so this layer just sequences the request handling.
public actor Routes {
    private let deviceStore: DeviceStore
    private let config: RelayConfig
    private let auth: AuthService
    private let allowLocalhost: Bool
    /// Serves the browser client when configured. `nil` keeps the relay
    /// API-only, which is what every existing deployment (and the iOS app)
    /// expects, so unknown paths stay 404.
    private let staticFiles: StaticFileServer?
    /// Whether this Mac's own tailnet login counts as authorised. See
    /// `resolveSelfLogin()`. Opt out with `CMUX_NO_SELF_LOGIN=1`.
    private let selfLoginEnabled: Bool
    /// Memoised result of `auth.selfLogin()`. Only a *successful* lookup is
    /// stored — a failure must stay retryable, which is the whole point of
    /// resolving here instead of once at startup.
    private var cachedSelfLogin: String?
    private let logger: Logger

    public init(deviceStore: DeviceStore,
                config: RelayConfig,
                auth: AuthService,
                allowLocalhost: Bool = Routes.defaultAllowLocalhost(),
                webRoot: URL? = nil,
                selfLoginEnabled: Bool = Routes.defaultSelfLoginEnabled(),
                logger: Logger = Logger(label: "Routes"))
    {
        self.deviceStore = deviceStore
        self.config = config
        self.auth = auth
        self.allowLocalhost = allowLocalhost
        self.staticFiles = webRoot.map(StaticFileServer.init(root:))
        self.selfLoginEnabled = selfLoginEnabled
        self.logger = logger
    }

    /// Reads `CMUX_DEV_ALLOW_LOCALHOST=1` from the environment. When true,
    /// loopback callers (`127.0.0.1` / `::1`) bypass `tailscaled.whois` —
    /// macOS short-circuits packets to the local Tailscale IP through `lo0`,
    /// so the iOS Simulator on the same Mac can never produce a remote
    /// address tailscaled will recognise. We keep the bypass opt-in so it
    /// never ships to a production binding.
    public static func defaultAllowLocalhost() -> Bool {
        ProcessInfo.processInfo.environment["CMUX_DEV_ALLOW_LOCALHOST"] == "1"
    }

    /// Reads the `CMUX_NO_SELF_LOGIN=1` opt-out. Default on: the relay runs on
    /// the operator's own Mac, so its tailnet login is the account their phone
    /// signs in with.
    public static func defaultSelfLoginEnabled() -> Bool {
        ProcessInfo.processInfo.environment["CMUX_NO_SELF_LOGIN"] == nil
    }

    /// Top-level dispatch. `deviceId` is `nil` until the HTTP layer has
    /// validated the bearer token (M3.11) — `Routes` itself does not
    /// re-validate, so authenticated paths short-circuit on `deviceId == nil`.
    public func handle(method: HTTPMethod,
                       path: String,
                       body: Data?,
                       deviceId: String?,
                       remoteAddr: String) async -> HTTPResponseLite
    {
        switch (method, path) {
        case (.GET, "/v1/health"):
            return .init(.ok, body: Data(#"{"ok":true}"#.utf8))

        case (.GET, "/v1/state"):
            return state()

        case (.POST, "/v1/devices/me/register"):
            return await registerNew(remoteAddr: remoteAddr)

        case (.POST, "/v1/devices/me/apns"):
            guard let did = deviceId,
                  deviceStore.lookup(deviceId: did) != nil else {
                return .init(.unauthorized)
            }
            return registerApns(deviceId: did, body: body)

        case (.DELETE, "/v1/devices/me"):
            guard let did = deviceId else { return .init(.unauthorized) }
            try? deviceStore.revoke(deviceId: did)
            return .init(.noContent)

        default:
            // The browser client is the only thing served outside `/v1`, and
            // only for GET. Holding the API namespace back means a typo'd
            // endpoint stays a 404 instead of quietly serving a file that
            // happens to sit at that name.
            if method == .GET, !path.hasPrefix("/v1/"), let staticFiles {
                return staticFiles.response(for: path)
            }
            return .init(.notFound)
        }
    }

    // MARK: - GET /v1/state

    private func state() -> HTTPResponseLite {
        struct State: Encodable {
            let snippets: [RelayConfig.Snippet]
            let defaultFps: Int
            enum CodingKeys: String, CodingKey {
                case snippets, defaultFps = "default_fps"
            }
        }
        let s = State(snippets: config.snippets, defaultFps: config.defaultFps)
        let body = (try? JSONEncoder().encode(s)) ?? Data()
        return .init(.ok, body: body)
    }

    // MARK: - POST /v1/devices/me/apns

    private func registerApns(deviceId: String, body: Data?) -> HTTPResponseLite {
        struct Payload: Decodable {
            let apnsToken: String
            let env: String
            enum CodingKeys: String, CodingKey {
                case apnsToken = "apns_token", env
            }
        }
        guard let body,
              let p = try? JSONDecoder().decode(Payload.self, from: body),
              Self.isAPNsToken(p.apnsToken) else {
            return .init(.badRequest)
        }
        guard p.env == "prod" || p.env == "sandbox" else {
            return .init(.badRequest)
        }
        try? deviceStore.setAPNsToken(deviceId: deviceId,
                                      token: p.apnsToken, env: p.env)
        return .init(.noContent)
    }

    private static func isAPNsToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count.isMultiple(of: 2) && token.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...70).contains(byte)
                || (97...102).contains(byte)
        }
    }

    // MARK: - Pairing authorisation

    /// Whether `login` may pair a new device.
    ///
    /// `allow_login` wins outright. Beyond it, this Mac's own tailnet login is
    /// authorised automatically — a fresh `relay.json` lists nobody, and
    /// demanding the operator hand-copy their own email before their phone can
    /// connect is a pointless step that 403s every device until they find it.
    ///
    /// That lookup happens *here*, per request, rather than once at startup.
    /// The relay is a launchd agent with `RunAtLoad`, so on a reboot it races
    /// tailscaled — and losing that race once used to bake an empty allow-list
    /// in for the whole process lifetime: every pairing 403s until someone
    /// restarts the relay by hand, with nothing in the log to say why.
    /// Resolving lazily lets the first request after tailscaled is up heal it.
    private func isAuthorised(_ login: String) async -> Bool {
        if config.allowLogin.contains(login) { return true }
        guard selfLoginEnabled else { return false }
        return await resolveSelfLogin() == login
    }

    /// This Mac's tailnet login, memoised. Failures are deliberately not
    /// cached: tailscaled being unreachable is a transient boot condition, and
    /// caching nil would reintroduce the permanent-403 bug this replaced.
    private func resolveSelfLogin() async -> String? {
        if let cachedSelfLogin { return cachedSelfLogin }
        guard let login = await auth.selfLogin() else { return nil }
        cachedSelfLogin = login
        logger.info("auto-authorising this Mac's tailnet login for pairing: \(login)")
        return login
    }

    // MARK: - POST /v1/devices/me/register

    private func registerNew(remoteAddr: String) async -> HTTPResponseLite {
        let peer: PeerIdentity
        if allowLocalhost, Self.isLoopback(remoteAddr), let login = config.allowLogin.first {
            // Dev bypass — see `defaultAllowLocalhost()`. The peer identity
            // is fabricated from the first allow_login so the simulator can
            // pair without traversing tailscaled. nodeKey is a stable
            // synthetic value so re-registering yields the same deviceId.
            peer = PeerIdentity(
                loginName: login,
                hostname: "localhost-dev",
                os: "ios-simulator",
                nodeKey: "cmux-dev-localhost:\(login)"
            )
        } else {
            do {
                peer = try await auth.whois(remoteAddr: remoteAddr)
            } catch RelayError.unauthorized {
                // tailscaled didn't recognize the peer at all — treat as
                // forbidden so the phone shows a clear "not on tailnet" UI
                // rather than a 5xx that suggests a relay bug.
                return .init(.forbidden)
            } catch {
                return .init(.internalServerError)
            }

            guard await isAuthorised(peer.loginName) else {
                return .init(.forbidden)
            }
        }

        let deviceId = sha256Hex(peer.nodeKey)
        // Idempotent: rebinding the same node rotates the bearer so the
        // previous token (which may have leaked) is no longer valid.
        try? deviceStore.revoke(deviceId: deviceId)
        do {
            let token = try deviceStore.register(deviceId: deviceId,
                                                 loginName: peer.loginName,
                                                 hostname: peer.hostname,
                                                 apnsToken: nil)
            struct R: Encodable {
                let device_id: String
                let token: String
            }
            let body = try JSONEncoder().encode(R(device_id: deviceId, token: token))
            return .init(.ok, body: body)
        } catch {
            return .init(.internalServerError)
        }
    }
}

private func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

extension Routes {
    static func isLoopback(_ addr: String) -> Bool {
        addr == "127.0.0.1" || addr == "::1" || addr == "0:0:0:0:0:0:0:1"
    }
}
