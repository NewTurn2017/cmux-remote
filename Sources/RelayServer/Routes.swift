import Foundation
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
    public init(_ status: HTTPResponseStatus, body: Data? = nil) {
        self.status = status; self.body = body
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

    public init(deviceStore: DeviceStore, config: RelayConfig, auth: AuthService) {
        self.deviceStore = deviceStore
        self.config = config
        self.auth = auth
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
              !p.apnsToken.isEmpty else {
            return .init(.badRequest)
        }
        guard p.env == "prod" || p.env == "sandbox" else {
            return .init(.badRequest)
        }
        try? deviceStore.setAPNsToken(deviceId: deviceId,
                                      token: p.apnsToken, env: p.env)
        return .init(.noContent)
    }

    // MARK: - POST /v1/devices/me/register

    private func registerNew(remoteAddr: String) async -> HTTPResponseLite {
        let peer: PeerIdentity
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

        guard config.allowLogin.contains(peer.loginName) else {
            return .init(.forbidden)
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
