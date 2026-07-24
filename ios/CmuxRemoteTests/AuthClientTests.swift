import XCTest
@testable import CmuxRemote

final class AuthClientTests: XCTestCase {
    func testSuccessfulRegistrationClearsPairingCodeOnlyInBrokerMode() throws {
        let suiteName = "pairing-code.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("pair-secret", forKey: "cmux.pairingCode")
        CmuxRemoteApp.clearStoredPairingCode(
            afterSuccessfulRegistration: .direct,
            defaults: defaults
        )
        XCTAssertEqual(defaults.string(forKey: "cmux.pairingCode"), "pair-secret")

        CmuxRemoteApp.clearStoredPairingCode(
            afterSuccessfulRegistration: .broker,
            defaults: defaults
        )
        XCTAssertNil(defaults.string(forKey: "cmux.pairingCode"))
    }

    func testRegisterStoresBearer() async throws {
        let keychain = Keychain(service: "auth.\(UUID().uuidString)")
        let mock = MockHTTPClient { request in
            XCTAssertEqual(request.url?.absoluteString, "http://mac.tailnet.ts.net:4399/v1/devices/me/register")
            return (Data(#"{"device_id":"d1","token":"abc"}"#.utf8), 200)
        }
        let client = AuthClient(host: "mac.tailnet.ts.net", port: 4399, keychain: keychain, http: mock)
        try await client.registerIfNeeded()
        XCTAssertEqual(try keychain.get("device_id"), "d1")
        XCTAssertEqual(try keychain.get("bearer"), "abc")
        XCTAssertEqual(
            try keychain.get("relay_endpoint"),
            "direct|http://mac.tailnet.ts.net:4399"
        )
    }

    func testBrokerRegisterSendsPairingPayloadAndStoresScopedCredentials() async throws {
        let keychain = Keychain(service: "auth.\(UUID().uuidString)")
        let endpoint = RelayEndpoint.broker(
            baseURL: "https://relay.example.com/cmux",
            relayId: "home-mac"
        )
        let mock = MockHTTPClient { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://relay.example.com/cmux/v1/devices/me/register"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try! XCTUnwrap(request.httpBody)
            let object = try! JSONSerialization.jsonObject(with: body) as! [String: String]
            XCTAssertEqual(object["relay_id"], "home-mac")
            XCTAssertEqual(object["pairing_code"], "pair-secret")
            XCTAssertEqual(object["client_id"], "phone-client")
            XCTAssertEqual(object["device_name"], "My iPhone")
            return (Data(#"{"device_id":"d-server","token":"server-token"}"#.utf8), 200)
        }
        let client = AuthClient(
            endpoint: endpoint,
            keychain: keychain,
            http: mock,
            pairingCode: "pair-secret",
            clientId: "phone-client",
            deviceName: "My iPhone"
        )

        try await client.registerIfNeeded()

        XCTAssertEqual(try keychain.get("device_id"), "d-server")
        XCTAssertEqual(try keychain.get("bearer"), "server-token")
        XCTAssertEqual(
            try keychain.get("relay_endpoint"),
            "broker|https://relay.example.com/cmux|home-mac"
        )
    }

    func testBrokerRegisterRequiresPairingCodeBeforeNetwork() async throws {
        let keychain = Keychain(service: "auth.\(UUID().uuidString)")
        let mock = MockHTTPClient { _ in
            XCTFail("network should not be hit")
            return (Data(), 500)
        }
        let client = AuthClient(
            endpoint: .broker(baseURL: "https://relay.example.com", relayId: "home-mac"),
            keychain: keychain,
            http: mock,
            clientId: "phone-client",
            deviceName: "My iPhone"
        )

        do {
            try await client.registerIfNeeded()
            XCTFail("expected missingPairingCode")
        } catch AuthError.missingPairingCode {}
    }

    func testBrokerRejectsInsecurePublicURLBeforeNetwork() async throws {
        let keychain = Keychain(service: "auth.\(UUID().uuidString)")
        let mock = MockHTTPClient { _ in
            XCTFail("network should not be hit")
            return (Data(), 500)
        }
        let client = AuthClient(
            endpoint: .broker(baseURL: "http://relay.example.com", relayId: "home-mac"),
            keychain: keychain,
            http: mock,
            pairingCode: "pair-secret",
            clientId: "phone-client",
            deviceName: "My iPhone"
        )

        do {
            try await client.registerIfNeeded()
            XCTFail("expected insecureBrokerURL")
        } catch AuthError.insecureBrokerURL {}
    }

    func testNoOpWhenAlreadyRegistered() async throws {
        let keychain = Keychain(service: "auth.\(UUID().uuidString)")
        try keychain.set("d1", for: "device_id")
        try keychain.set("abc", for: "bearer")
        try keychain.set("x.ts.net", for: "relay_host")
        let hitCount = LockBox(0)
        let mock = MockHTTPClient { _ in
            hitCount.withValue { $0 += 1 }
            return (Data(), 200)
        }
        let client = AuthClient(host: "x.ts.net", port: 4399, keychain: keychain, http: mock)
        try await client.registerIfNeeded()
        XCTAssertEqual(hitCount.withValue { $0 }, 0)
    }

    func testRejectsNonTailscaleHostBeforeSendingBearer() async throws {
        let keychain = Keychain(service: "auth.\(UUID().uuidString)")
        try keychain.set("d1", for: "device_id")
        try keychain.set("abc", for: "bearer")
        let mock = MockHTTPClient { _ in XCTFail("network should not be hit"); return (Data(), 500) }
        let client = AuthClient(host: "example.com", port: 4399, keychain: keychain, http: mock)
        do {
            try await client.registerIfNeeded()
            XCTFail("expected disallowedHost")
        } catch AuthError.disallowedHost {}
    }

    func testHostChangeClearsAndReRegisters() async throws {
        let keychain = Keychain(service: "auth.\(UUID().uuidString)")
        try keychain.set("old", for: "device_id")
        try keychain.set("old-token", for: "bearer")
        try keychain.set("old.ts.net", for: "relay_host")
        let mock = MockHTTPClient { _ in
            (Data(#"{"device_id":"new","token":"new-token"}"#.utf8), 200)
        }
        let client = AuthClient(host: "new.ts.net", port: 4399, keychain: keychain, http: mock)
        try await client.registerIfNeeded()
        XCTAssertEqual(try keychain.get("device_id"), "new")
        XCTAssertEqual(try keychain.get("bearer"), "new-token")
        XCTAssertEqual(try keychain.get("relay_host"), "new.ts.net")
    }

    func testRegisterAPNsTokenPostsBearerAndPayload() async throws {
        let keychain = Keychain(service: "auth.\(UUID().uuidString)")
        try keychain.set("d1", for: "device_id")
        try keychain.set("abc", for: "bearer")
        try keychain.set("mac.tailnet.ts.net", for: "relay_host")
        let mock = MockHTTPClient { request in
            XCTAssertEqual(request.url?.absoluteString, "http://mac.tailnet.ts.net:4399/v1/devices/me/apns")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try! XCTUnwrap(request.httpBody)
            let object = try! JSONSerialization.jsonObject(with: body) as! [String: String]
            XCTAssertEqual(object["apns_token"], "00ff10")
            XCTAssertEqual(object["env"], "sandbox")
            return (Data(), 204)
        }
        let client = AuthClient(host: "mac.tailnet.ts.net", port: 4399, keychain: keychain, http: mock)

        try await client.registerAPNsTokenHex("00ff10", environment: .sandbox)
    }

    func testRegisterAPNsTokenRequiresBearerBeforeNetwork() async throws {
        let keychain = Keychain(service: "auth.\(UUID().uuidString)")
        let mock = MockHTTPClient { _ in XCTFail("network should not be hit"); return (Data(), 500) }
        let client = AuthClient(host: "mac.tailnet.ts.net", port: 4399, keychain: keychain, http: mock)

        do {
            try await client.registerAPNsTokenHex("00ff10", environment: .sandbox)
            XCTFail("expected missingBearer")
        } catch AuthError.missingBearer {}
    }

    func testRegisterAPNsTokenRejectsDisallowedHostBeforeNetwork() async throws {
        let keychain = Keychain(service: "auth.\(UUID().uuidString)")
        try keychain.set("abc", for: "bearer")
        let mock = MockHTTPClient { _ in XCTFail("network should not be hit"); return (Data(), 500) }
        let client = AuthClient(host: "example.com", port: 4399, keychain: keychain, http: mock)

        do {
            try await client.registerAPNsTokenHex("00ff10", environment: .sandbox)
            XCTFail("expected disallowedHost")
        } catch AuthError.disallowedHost {}
    }

    func testBrokerAPNsRegistrationUsesRelayScopedHTTPSRoute() async throws {
        let keychain = Keychain(service: "auth.\(UUID().uuidString)")
        let endpoint = RelayEndpoint.broker(
            baseURL: "https://relay.example.com",
            relayId: "home-mac"
        )
        try keychain.set("d1", for: "device_id")
        try keychain.set("abc", for: "bearer")
        try keychain.set(try endpoint.credentialIdentity(), for: "relay_endpoint")
        let mock = MockHTTPClient { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://relay.example.com/v1/devices/me/apns?relay_id=home-mac"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
            return (Data(), 204)
        }
        let client = AuthClient(endpoint: endpoint, keychain: keychain, http: mock)

        try await client.registerAPNsTokenHex("00ff10", environment: .sandbox)
    }
}

final class MockHTTPClient: HTTPClientFacade, @unchecked Sendable {
    let handler: @Sendable (URLRequest) -> (Data, Int)
    init(handler: @escaping @Sendable (URLRequest) -> (Data, Int)) { self.handler = handler }
    func request(_ request: URLRequest) async throws -> (Data, Int) { handler(request) }
}

final class LockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
