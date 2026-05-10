import XCTest
import NIOHTTP1
@testable import RelayServer
@testable import RelayCore

final class RoutesTests: XCTestCase {
    private func makeRoutes(
        _ store: DeviceStore,
        allow: [String] = ["a@b"],
        peers: [String: PeerIdentity] = [
            "100.64.0.5": .init(loginName: "a@b",
                                hostname: "iPhone",
                                os: "ios",
                                nodeKey: "nk1")
        ]
    ) -> Routes {
        var cfg = RelayConfig.testValue
        cfg.allowLogin = allow
        return Routes(deviceStore: store,
                      config: cfg,
                      auth: MockAuthService(peers: peers))
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

    func testApnsNeedsAuth() async throws {
        // No deviceId on the request → 401 even though body is well-formed.
        let resp = await makeRoutes(try DeviceStore.empty())
            .handle(method: .POST, path: "/v1/devices/me/apns",
                    body: Data(#"{"apns_token":"t","env":"prod"}"#.utf8),
                    deviceId: nil, remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .unauthorized)
    }

    func testApnsPersists() async throws {
        let store = try DeviceStore.empty()
        _ = try store.register(deviceId: "d", loginName: "a",
                               hostname: "h", apnsToken: nil)
        let resp = await makeRoutes(store)
            .handle(method: .POST, path: "/v1/devices/me/apns",
                    body: Data(#"{"apns_token":"t","env":"prod"}"#.utf8),
                    deviceId: "d", remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .noContent)
        XCTAssertEqual(store.lookup(deviceId: "d")?.apnsToken, "t")
        XCTAssertEqual(store.lookup(deviceId: "d")?.apnsEnv, "prod")
    }

    func testApnsRejectsBadEnv() async throws {
        let store = try DeviceStore.empty()
        _ = try store.register(deviceId: "d", loginName: "a",
                               hostname: "h", apnsToken: nil)
        let resp = await makeRoutes(store)
            .handle(method: .POST, path: "/v1/devices/me/apns",
                    body: Data(#"{"apns_token":"t","env":"bogus"}"#.utf8),
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
