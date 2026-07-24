import XCTest
import Foundation
@testable import RelayCore

/// Covers `TailscaledLocalAuth.parseSelfLogin`, which extracts the relay
/// host's own tailnet login from a `tailscale status` payload. The live
/// socket/CLI resolution path needs a running tailscaled and is exercised in
/// integration, not here.
final class SelfLoginTests: XCTestCase {
    func testParsesSelfLoginFromStatus() {
        let json = #"{"Self":{"UserID":42},"User":{"42":{"LoginName":"alice@example.com"}}}"#
        XCTAssertEqual(TailscaledLocalAuth.parseSelfLogin(Data(json.utf8)), "alice@example.com")
    }

    func testTaggedNodeHasNoSelfLogin() {
        // Tagged/headless nodes report UserID 0 and carry no user profile.
        let json = #"{"Self":{"UserID":0},"User":{}}"#
        XCTAssertNil(TailscaledLocalAuth.parseSelfLogin(Data(json.utf8)))
    }

    func testMalformedOrIncompleteStatusIsNil() {
        XCTAssertNil(TailscaledLocalAuth.parseSelfLogin(Data("not json".utf8)))
        // UserID present but no matching User entry → nil, never a crash.
        XCTAssertNil(TailscaledLocalAuth.parseSelfLogin(Data(#"{"Self":{"UserID":42},"User":{}}"#.utf8)))
    }
}
