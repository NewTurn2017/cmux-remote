import XCTest
import Foundation
@testable import RelayServer
@testable import RelayCore

final class HTTPServerTests: XCTestCase {

    /// Wraps a test body so the fixture's NIO event loop group is always
    /// shut down before the test method returns. A bare `defer { Task { ... } }`
    /// would fire-and-forget the shutdown and leave background work pinned
    /// to the group across tests.
    private func withFixture(
        allowLogin: [String] = ["a@b"],
        _ body: (HTTPServerFixture) async throws -> Void
    ) async throws {
        let fx = try await HTTPServerFixture.make(allowLogin: allowLogin)
        do {
            try await body(fx)
            await fx.shutdown()
        } catch {
            await fx.shutdown()
            throw error
        }
    }

    // MARK: - HTTP routing

    func testHealthGetReturns200WithBody() async throws {
        try await withFixture { fx in
            let resp = try await fx.rawRequest(
                "GET /v1/health HTTP/1.1\r\nHost: \(fx.host)\r\nConnection: close\r\n\r\n"
            )
            XCTAssertEqual(resp.statusCode, 200)
            XCTAssertTrue(resp.bodyString.contains(#""ok":true"#),
                          "expected ok=true, got: \(resp.bodyString)")
        }
    }

    func testRegisterAnonymouslyIssuesToken() async throws {
        try await withFixture { fx in
            let resp = try await fx.rawRequest(
                "POST /v1/devices/me/register HTTP/1.1\r\nHost: \(fx.host)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )
            XCTAssertEqual(resp.statusCode, 200, "body=\(resp.bodyString)")

            struct R: Decodable {
                let deviceId: String
                let token: String
                enum CodingKeys: String, CodingKey { case deviceId = "device_id", token }
            }
            let r = try JSONDecoder().decode(R.self, from: resp.body)
            XCTAssertFalse(r.token.isEmpty)
            XCTAssertNotNil(fx.deviceStore.lookup(deviceId: r.deviceId))
            XCTAssertTrue(fx.deviceStore.validate(deviceId: r.deviceId, token: r.token))
        }
    }

    func testApnsWithoutBearerReturns401() async throws {
        try await withFixture { fx in
            let body = #"{"apns_token":"t","env":"prod"}"#
            let resp = try await fx.rawRequest(
                "POST /v1/devices/me/apns HTTP/1.1\r\nHost: \(fx.host)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            )
            XCTAssertEqual(resp.statusCode, 401)
        }
    }

    func testApnsWithValidBearerPersists() async throws {
        try await withFixture { fx in
            let token = try fx.deviceStore.register(deviceId: "d-apns",
                                                    loginName: "a@b",
                                                    hostname: "iPhone",
                                                    apnsToken: nil)
            let body = #"{"apns_token":"abc-token","env":"prod"}"#
            let resp = try await fx.rawRequest(
                "POST /v1/devices/me/apns HTTP/1.1\r\nHost: \(fx.host)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            )
            XCTAssertEqual(resp.statusCode, 204, "body=\(resp.bodyString)")
            XCTAssertEqual(fx.deviceStore.lookup(deviceId: "d-apns")?.apnsToken,
                           "abc-token")
            XCTAssertEqual(fx.deviceStore.lookup(deviceId: "d-apns")?.apnsEnv, "prod")
        }
    }

    func testApnsWithUnknownBearerReturns401() async throws {
        try await withFixture { fx in
            let body = #"{"apns_token":"t","env":"prod"}"#
            let resp = try await fx.rawRequest(
                "POST /v1/devices/me/apns HTTP/1.1\r\nHost: \(fx.host)\r\nAuthorization: Bearer not-a-real-token\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            )
            XCTAssertEqual(resp.statusCode, 401)
        }
    }

    // MARK: - WebSocket upgrade

    func testWebSocketUpgradeWithValidBearerReturns101() async throws {
        try await withFixture { fx in
            let token = try fx.deviceStore.register(deviceId: "d-ws",
                                                    loginName: "a@b",
                                                    hostname: "iPhone",
                                                    apnsToken: nil)
            let resp = try await fx.rawRequest(
                "GET /v1/ws HTTP/1.1\r\nHost: \(fx.host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: cmuxremote.v1, bearer.\(token)\r\n\r\n"
            )
            XCTAssertEqual(resp.statusCode, 101,
                           "expected upgrade, got \(resp.statusCode): \(resp.bodyString)")
        }
    }

    func testWebSocketUpgradeWithoutBearerIsRejected() async throws {
        try await withFixture { fx in
            let resp = try await fx.rawRequest(
                "GET /v1/ws HTTP/1.1\r\nHost: \(fx.host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
            )
            XCTAssertNotEqual(resp.statusCode, 101,
                              "WS upgrade without bearer must not succeed; got \(resp.statusCode)")
        }
    }
}
