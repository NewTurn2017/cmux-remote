import XCTest
import Crypto
@testable import RelayCore

final class DeviceStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
    }

    func testRegisterPersistsHashedToken() throws {
        let url = tempURL()
        let store = try DeviceStore(url: url)
        let token = try store.register(
            deviceId: "dev1", loginName: "a@b", hostname: "iPhone15", apnsToken: nil)
        XCTAssertGreaterThan(token.count, 32)              // raw bearer
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let dev = try XCTUnwrap(store.lookup(deviceId: "dev1"))
        XCTAssertNotEqual(dev.tokenHash, token)            // store hashed
    }

    func testValidateTokenAcceptsCorrectAndRejectsForged() throws {
        let store = try DeviceStore(url: tempURL())
        let token = try store.register(
            deviceId: "dev1", loginName: "a@b", hostname: "iPhone", apnsToken: nil)
        XCTAssertTrue(store.validate(deviceId: "dev1", token: token))
        XCTAssertFalse(store.validate(deviceId: "dev1", token: "wrong"))
    }

    func testRevokeRemovesDevice() throws {
        let store = try DeviceStore(url: tempURL())
        _ = try store.register(deviceId: "d", loginName: "a", hostname: "h", apnsToken: nil)
        try store.revoke(deviceId: "d")
        XCTAssertNil(store.lookup(deviceId: "d"))
    }

    func testMalformedRegistryFailsLoudly() throws {
        let url = tempURL()
        try Data("not-json".utf8).write(to: url)

        XCTAssertThrowsError(try DeviceStore(url: url)) { error in
            XCTAssertEqual(error as? DeviceStoreError, .invalidState(url.path))
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("not-json".utf8))
    }

    func testRegistryFileUsesOwnerOnlyPermissions() throws {
        let url = tempURL()
        _ = try DeviceStore(url: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testFailedWriteLeavesInMemoryRegistrationUnchanged() throws {
        let url = tempURL()
        try DeviceStore.persistToDisk([:], url)
        let store = try DeviceStore(url: url) { _, _ in
            throw PersistenceFailure.write
        }

        XCTAssertThrowsError(try store.register(
            deviceId: "d", loginName: "a", hostname: "h", apnsToken: nil
        ))
        XCTAssertNil(store.lookup(deviceId: "d"))
    }

    func testApnsTokenUpdate() throws {
        let store = try DeviceStore(url: tempURL())
        _ = try store.register(deviceId: "d", loginName: "a", hostname: "h", apnsToken: nil)
        try store.setAPNsToken(deviceId: "d", token: "apns-1", env: "prod")
        XCTAssertEqual(store.lookup(deviceId: "d")?.apnsToken, "apns-1")
        XCTAssertEqual(store.lookup(deviceId: "d")?.apnsEnv, "prod")
    }
}

private enum PersistenceFailure: Error {
    case write
}
