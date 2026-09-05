import XCTest
import NIOHTTP1
@testable import RelayServer
@testable import RelayCore

final class RoutesTests: XCTestCase {
    private static let defaultPeers: [String: PeerIdentity] = [
        "100.64.0.5": .init(loginName: "a@b",
                            hostname: "iPhone",
                            os: "ios",
                            nodeKey: "nk1")
    ]

    private func makeRoutes(
        _ store: DeviceStore,
        allow: [String] = ["a@b"],
        peers: [String: PeerIdentity] = RoutesTests.defaultPeers,
        auth: MockAuthService? = nil,
        selfLoginEnabled: Bool = true
    ) -> Routes {
        var cfg = RelayConfig.testValue
        cfg.allowLogin = allow
        return Routes(deviceStore: store,
                      config: cfg,
                      auth: auth ?? MockAuthService(peers: peers),
                      selfLoginEnabled: selfLoginEnabled)
    }

    /// POSTs a register for the peer at `100.64.0.5` and returns the status.
    private func register(_ routes: Routes) async -> HTTPResponseStatus {
        await routes.handle(method: .POST,
                            path: "/v1/devices/me/register",
                            body: nil, deviceId: nil,
                            remoteAddr: "100.64.0.5:1").status
    }

    func testHealthOk() async throws {
        let resp = await makeRoutes(try DeviceStore.empty())
            .handle(method: .GET, path: "/v1/health",
                    body: nil, deviceId: nil, remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .ok)
    }

    func testRegisterCreatesDeviceAndIssuesToken() async throws {
        let store = try DeviceStore.empty()
        let routes = makeRoutes(store)
        let resp = await routes.handle(method: .POST,
                                       path: "/v1/devices/me/register",
                                       body: nil, deviceId: nil,
                                       remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .ok)

        struct R: Decodable {
            let deviceId: String
            let token: String
            enum CodingKeys: String, CodingKey {
                case deviceId = "device_id", token
            }
        }
        let r = try JSONDecoder().decode(R.self, from: resp.body ?? Data())
        XCTAssertFalse(r.token.isEmpty)
        XCTAssertNotNil(store.lookup(deviceId: r.deviceId))
        XCTAssertTrue(store.validate(deviceId: r.deviceId, token: r.token))
    }

    func testRegisterRejectsLoginNotInAllowList() async throws {
        let store = try DeviceStore.empty()
        let routes = makeRoutes(store, allow: ["someone@else"])
        let resp = await routes.handle(method: .POST,
                                       path: "/v1/devices/me/register",
                                       body: nil, deviceId: nil,
                                       remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .forbidden)
    }

    func testRegisterRejectsUnknownPeer() async throws {
        // peer table empty → MockAuthService.whois throws unauthorized
        let resp = await makeRoutes(try DeviceStore.empty(), peers: [:])
            .handle(method: .POST, path: "/v1/devices/me/register",
                    body: nil, deviceId: nil, remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .forbidden)
    }

    // MARK: - Pairing on this Mac's own tailnet login

    func testRegisterAuthorisesThisMacsOwnLoginWhenAllowListEmpty() async throws {
        // A fresh relay.json lists nobody; the operator's own login pairs anyway.
        let auth = MockAuthService(peers: RoutesTests.defaultPeers, selfLogin: "a@b")
        let routes = makeRoutes(try DeviceStore.empty(), allow: [], auth: auth)
        let status = await register(routes)
        XCTAssertEqual(status, .ok)
    }

    /// Regression: the relay is a launchd agent with `RunAtLoad`, so on a
    /// reboot it can ask tailscaled who it is before tailscaled is ready.
    /// Resolving that once at startup baked an empty allow-list in for the
    /// whole process lifetime — every device 403'd until someone restarted the
    /// relay by hand. The lookup must stay retryable.
    func testRegisterHealsOnceTailscaledBecomesReachable() async throws {
        let auth = MockAuthService(peers: RoutesTests.defaultPeers, selfLogin: nil)
        let routes = makeRoutes(try DeviceStore.empty(), allow: [], auth: auth)

        let duringBoot = await register(routes)
        XCTAssertEqual(duringBoot, .forbidden)

        auth.selfLoginValue = "a@b"   // tailscaled finished starting
        let afterBoot = await register(routes)
        XCTAssertEqual(afterBoot, .ok, "a failed lookup must not be cached")
    }

    func testRegisterMemoisesResolvedSelfLogin() async throws {
        let auth = MockAuthService(peers: RoutesTests.defaultPeers, selfLogin: "a@b")
        let routes = makeRoutes(try DeviceStore.empty(), allow: [], auth: auth)

        _ = await register(routes)
        _ = await register(routes)
        XCTAssertEqual(auth.selfLoginCallCount, 1,
                       "a resolved login must not re-query tailscaled per request")
    }

    func testRegisterIgnoresSelfLoginWhenOptedOut() async throws {
        // CMUX_NO_SELF_LOGIN=1 — allow_login is then the only authority.
        let auth = MockAuthService(peers: RoutesTests.defaultPeers, selfLogin: "a@b")
        let routes = makeRoutes(try DeviceStore.empty(), allow: [],
                                auth: auth, selfLoginEnabled: false)
        let status = await register(routes)
        XCTAssertEqual(status, .forbidden)
        XCTAssertEqual(auth.selfLoginCallCount, 0)
    }

    func testRegisterRejectsPeerThatIsNotThisMacsLogin() async throws {
        // Self-login resolves, but to a different account than the caller's.
        let auth = MockAuthService(peers: RoutesTests.defaultPeers,
                                   selfLogin: "someone@else")
        let routes = makeRoutes(try DeviceStore.empty(), allow: [], auth: auth)
        let status = await register(routes)
        XCTAssertEqual(status, .forbidden)
    }

    func testApnsNeedsAuth() async throws {
        // No deviceId on the request → 401 even though body is well-formed.
        let resp = await makeRoutes(try DeviceStore.empty())
            .handle(method: .POST, path: "/v1/devices/me/apns",
                    body: Data(#"{"apns_token":"abcdef1234","env":"prod"}"#.utf8),
                    deviceId: nil, remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .unauthorized)
    }

    func testApnsPersists() async throws {
        let store = try DeviceStore.empty()
        _ = try store.register(deviceId: "d", loginName: "a",
                               hostname: "h", apnsToken: nil)
        let resp = await makeRoutes(store)
            .handle(method: .POST, path: "/v1/devices/me/apns",
                    body: Data(#"{"apns_token":"abcdef1234","env":"prod"}"#.utf8),
                    deviceId: "d", remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .noContent)
        XCTAssertEqual(store.lookup(deviceId: "d")?.apnsToken, "abcdef1234")
        XCTAssertEqual(store.lookup(deviceId: "d")?.apnsEnv, "prod")
    }

    func testApnsRejectsMalformedToken() async throws {
        let store = try DeviceStore.empty()
        _ = try store.register(deviceId: "d", loginName: "a",
                               hostname: "h", apnsToken: nil)
        let resp = await makeRoutes(store)
            .handle(method: .POST, path: "/v1/devices/me/apns",
                    body: Data(#"{"apns_token":"not-a-hex-token","env":"prod"}"#.utf8),
                    deviceId: "d", remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .badRequest)
        XCTAssertNil(store.lookup(deviceId: "d")?.apnsToken)
    }

    func testApnsRejectsOddLengthHexToken() async throws {
        let store = try DeviceStore.empty()
        _ = try store.register(deviceId: "d", loginName: "a",
                               hostname: "h", apnsToken: nil)
        let resp = await makeRoutes(store)
            .handle(method: .POST, path: "/v1/devices/me/apns",
                    body: Data(#"{"apns_token":"abc","env":"prod"}"#.utf8),
                    deviceId: "d", remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .badRequest)
        XCTAssertNil(store.lookup(deviceId: "d")?.apnsToken)
    }

    func testApnsRejectsBadEnv() async throws {
        let store = try DeviceStore.empty()
        _ = try store.register(deviceId: "d", loginName: "a",
                               hostname: "h", apnsToken: nil)
        let resp = await makeRoutes(store)
            .handle(method: .POST, path: "/v1/devices/me/apns",
                    body: Data(#"{"apns_token":"abcdef1234","env":"bogus"}"#.utf8),
                    deviceId: "d", remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .badRequest)
    }

    func testStateReturnsConfigSnapshot() async throws {
        let resp = await makeRoutes(try DeviceStore.empty())
            .handle(method: .GET, path: "/v1/state",
                    body: nil, deviceId: nil, remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .ok)
        struct S: Decodable {
            let defaultFps: Int
            enum CodingKeys: String, CodingKey { case defaultFps = "default_fps" }
        }
        let s = try JSONDecoder().decode(S.self, from: resp.body ?? Data())
        XCTAssertEqual(s.defaultFps, 15)
    }

    func testRevokeRequiresAuth() async throws {
        let resp = await makeRoutes(try DeviceStore.empty())
            .handle(method: .DELETE, path: "/v1/devices/me",
                    body: nil, deviceId: nil, remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .unauthorized)
    }

    func testRevokeDropsDevice() async throws {
        let store = try DeviceStore.empty()
        _ = try store.register(deviceId: "d", loginName: "a",
                               hostname: "h", apnsToken: nil)
        XCTAssertNotNil(store.lookup(deviceId: "d"))
        let resp = await makeRoutes(store)
            .handle(method: .DELETE, path: "/v1/devices/me",
                    body: nil, deviceId: "d", remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .noContent)
        XCTAssertNil(store.lookup(deviceId: "d"))
    }

    func testUnknownPathIsNotFound() async throws {
        let resp = await makeRoutes(try DeviceStore.empty())
            .handle(method: .GET, path: "/nope",
                    body: nil, deviceId: nil, remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .notFound)
    }
}
