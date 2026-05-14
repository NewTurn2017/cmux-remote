import XCTest
@testable import CmuxRemote

final class KeychainTests: XCTestCase {
    func testRoundTrip() throws {
        let keychain = Keychain(service: "test.\(UUID().uuidString)")
        try keychain.set("token", for: "bearer")
        XCTAssertEqual(try keychain.get("bearer"), "token")
        try keychain.delete("bearer")
        XCTAssertNil(try keychain.get("bearer"))
    }
}
