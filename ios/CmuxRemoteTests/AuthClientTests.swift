import XCTest
@testable import CmuxRemote

final class AuthClientTests: XCTestCase {
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
