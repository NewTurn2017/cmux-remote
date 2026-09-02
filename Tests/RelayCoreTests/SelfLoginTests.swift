import XCTest
import Foundation
@testable import RelayCore

/// Covers `TailscaledLocalAuth.parseSelfLogin`, which extracts the relay
/// host's own tailnet login from a `tailscale status` payload. The live
/// socket/CLI resolution path needs a running tailscaled and is exercised in
/// integration, not here.
final class SelfLoginTests: XCTestCase {
    func testParsesSelfLoginFromStatus() throws {
        let json = #"{"BackendState":"Running","Self":{"UserID":42},"User":{"42":{"LoginName":"alice@example.com"}}}"#
        XCTAssertEqual(try TailscaledLocalAuth.parseSelfLogin(Data(json.utf8)), "alice@example.com")
    }

    func testTaggedNodeHasNoSelfLogin() throws {
        // Tagged/headless nodes report UserID 0 and carry no user profile.
        let json = #"{"BackendState":"Running","Self":{"UserID":0},"User":{}}"#
        XCTAssertNil(try TailscaledLocalAuth.parseSelfLogin(Data(json.utf8)))
    }

    func testUnavailableBackendThrows() {
        let json = #"{"BackendState":"Stopped","Self":{"UserID":42},"User":{}}"#
        XCTAssertThrowsError(try TailscaledLocalAuth.parseSelfLogin(Data(json.utf8))) { error in
            XCTAssertEqual(error as? TailnetIdentityError, .serviceUnavailable)
        }
    }

    func testMalformedOrIncompleteStatusThrows() {
        for data in [
            Data("not json".utf8),
            Data(#"{"BackendState":"Running","Self":{"UserID":42},"User":{}}"#.utf8),
        ] {
            XCTAssertThrowsError(try TailscaledLocalAuth.parseSelfLogin(data)) { error in
                XCTAssertEqual(error as? TailnetIdentityError, .invalidResponse)
            }
        }
    }
}
