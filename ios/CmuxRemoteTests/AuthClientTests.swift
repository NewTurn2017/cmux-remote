import XCTest
@testable import CmuxRemote

final class AuthClientTests: XCTestCase {
    func testRegisterStoresBearer() async throws {
        let keychain = makeKeychain()
        let mock = MockHTTPClient { request in
            XCTAssertEqual(request.url?.path, "/v1/devices/me/register")
            return .init(
                data: Data(#"{"device_id":"d1","token":"abc"}"#.utf8),
                statusCode: 200
            )
        }
        let client = makeClient(keychain: keychain, http: mock)

        let credentials = try await client.prepareCredentials()

        XCTAssertEqual(credentials, .init(deviceId: "d1", bearer: "abc"))
        XCTAssertEqual(try keychain.get("device_id"), "d1")
        XCTAssertEqual(try keychain.get("bearer"), "abc")
    }

    func testStoredBearerIsPreflightedBeforeUse() async throws {
        let keychain = makeKeychain()
        try seed(keychain, host: "mac.tailnet.ts.net")
        let mock = MockHTTPClient { request in
            XCTAssertEqual(request.url?.path, "/v1/devices/me")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
            return .init(data: Data(#"{"device_id":"d1"}"#.utf8), statusCode: 200)
        }
        let client = makeClient(keychain: keychain, http: mock)

        let credentials = try await client.prepareCredentials()

        XCTAssertEqual(credentials, .init(deviceId: "d1", bearer: "abc"))
    }

    func testLegacyRelayWithoutPreflightStillUsesStoredBearer() async throws {
        let keychain = makeKeychain()
        try seed(keychain, host: "mac.tailnet.ts.net")
        let mock = MockHTTPClient { _ in .init(data: Data(), statusCode: 404) }
        let client = makeClient(keychain: keychain, http: mock)

        let credentials = try await client.prepareCredentials()

        XCTAssertEqual(credentials, .init(deviceId: "d1", bearer: "abc"))
    }

    func testRevokedStoredBearerIsTerminalAndPreservedForExplicitRepair() async throws {
        let keychain = makeKeychain()
        try seed(keychain, host: "mac.tailnet.ts.net")
        let mock = MockHTTPClient { _ in .init(data: Data(), statusCode: 401) }
        let client = makeClient(keychain: keychain, http: mock)

        do {
            _ = try await client.prepareCredentials()
            XCTFail("expected pairingRemoved")
        } catch AuthError.pairingRemoved {}
        XCTAssertEqual(try keychain.get("bearer"), "abc")
    }

    func testRegistration503PreservesRetryAfter() async throws {
        let keychain = makeKeychain()
        let mock = MockHTTPClient { _ in
            .init(data: Data(), statusCode: 503, headers: ["Retry-After": "7"])
        }
        let client = makeClient(keychain: keychain, http: mock)

        do {
            _ = try await client.prepareCredentials()
            XCTFail("expected relayUnavailable")
        } catch AuthError.relayUnavailable(let status, let retryAfter) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(retryAfter, 7)
        }
    }

    func testRegistration403IsPermanentPolicyDenial() async throws {
        let client = makeClient(
            keychain: makeKeychain(),
            http: MockHTTPClient { _ in .init(data: Data(), statusCode: 403) }
        )

        do {
            _ = try await client.prepareCredentials()
            XCTFail("expected registrationDenied")
        } catch AuthError.registrationDenied {}
    }

    func testHostChangeClearsAndRegistersAgainstNewHost() async throws {
        let keychain = makeKeychain()
        try seed(keychain, host: "old.ts.net")
        let mock = MockHTTPClient { request in
            XCTAssertEqual(request.url?.host, "new.ts.net")
            XCTAssertEqual(request.url?.path, "/v1/devices/me/register")
            return .init(
                data: Data(#"{"device_id":"new","token":"new-token"}"#.utf8),
                statusCode: 200
            )
        }
        let client = makeClient(host: "new.ts.net", keychain: keychain, http: mock)

        _ = try await client.prepareCredentials()

        XCTAssertEqual(try keychain.get("device_id"), "new")
        XCTAssertEqual(try keychain.get("bearer"), "new-token")
        XCTAssertEqual(try keychain.get("relay_host"), "new.ts.net")
    }

    func testRegisterAPNsPreflightsThenPostsToken() async throws {
        let keychain = makeKeychain()
        try seed(keychain, host: "mac.tailnet.ts.net")
        let requests = LockBox<[URLRequest]>([])
        let mock = MockHTTPClient { request in
            requests.withValue { $0.append(request) }
            if request.url?.path == "/v1/devices/me" {
                return .init(data: Data(#"{"device_id":"d1"}"#.utf8), statusCode: 200)
            }
            XCTAssertEqual(request.url?.path, "/v1/devices/me/apns")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
            let body = try! XCTUnwrap(request.httpBody)
            let object = try! JSONSerialization.jsonObject(with: body) as! [String: String]
            XCTAssertEqual(object["apns_token"], "00ff10")
            XCTAssertEqual(object["env"], "sandbox")
            return .init(data: Data(), statusCode: 204)
        }
        let client = makeClient(keychain: keychain, http: mock)

        try await client.registerAPNsTokenHex("00ff10", environment: .sandbox)

        XCTAssertEqual(requests.withValue(\.count), 2)
    }

    func testRejectsNonTailscaleHostBeforeNetwork() async throws {
        let mock = MockHTTPClient { _ in
            XCTFail("network should not be hit")
            return .init(data: Data(), statusCode: 500)
        }
        let client = makeClient(host: "example.com", keychain: makeKeychain(), http: mock)

        do {
            _ = try await client.prepareCredentials()
            XCTFail("expected disallowedHost")
        } catch AuthError.disallowedHost {}
    }

    private func makeClient(
        host: String = "mac.tailnet.ts.net",
        keychain: Keychain,
        http: any HTTPClientFacade
    ) -> AuthClient {
        AuthClient(host: host, port: 4399, keychain: keychain, http: http)
    }

    private func makeKeychain() -> Keychain {
        Keychain(service: "auth.\(UUID().uuidString)")
    }

    private func seed(_ keychain: Keychain, host: String) throws {
        try keychain.set("d1", for: "device_id")
        try keychain.set("abc", for: "bearer")
        try keychain.set(host, for: "relay_host")
    }
}

final class MockHTTPClient: HTTPClientFacade, @unchecked Sendable {
    let handler: @Sendable (URLRequest) async throws -> HTTPClientResponse

    init(handler: @escaping @Sendable (URLRequest) async throws -> HTTPClientResponse) {
        self.handler = handler
    }

    func request(_ request: URLRequest) async throws -> HTTPClientResponse {
        try await handler(request)
    }
}

final class LockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
