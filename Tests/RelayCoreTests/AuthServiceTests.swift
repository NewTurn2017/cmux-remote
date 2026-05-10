import XCTest
@testable import RelayCore

final class AuthServiceTests: XCTestCase {
    func testMockResolvesPeer() async throws {
        let auth = MockAuthService(peers: [
            "100.64.0.5": .init(loginName: "a@b", hostname: "iPhone15", os: "iOS", nodeKey: "nodekey:nk1")
        ])
        let p = try await auth.whois(remoteAddr: "100.64.0.5")
        XCTAssertEqual(p.loginName, "a@b")
        XCTAssertEqual(p.hostname, "iPhone15")
        XCTAssertEqual(p.nodeKey, "nodekey:nk1")
    }

    func testMockResolvesPeerWithPort() async throws {
        let auth = MockAuthService(peers: [
            "100.64.0.5": .init(loginName: "a@b", hostname: "iPhone", os: "iOS", nodeKey: "nk1")
        ])
        let p = try await auth.whois(remoteAddr: "100.64.0.5:54321")
        XCTAssertEqual(p.loginName, "a@b")
    }

    func testMockResolvesIPv6PeerWithPort() async throws {
        let auth = MockAuthService(peers: [
            "fd7a:115c:a1e0::1": .init(loginName: "a@b", hostname: "iPhone", os: "iOS", nodeKey: "nk1")
        ])
        let p = try await auth.whois(remoteAddr: "[fd7a:115c:a1e0::1]:54321")
        XCTAssertEqual(p.loginName, "a@b")
    }

    func testMockRejectsUnknown() async throws {
        let auth = MockAuthService(peers: [:])
        do {
            _ = try await auth.whois(remoteAddr: "1.2.3.4")
            XCTFail("expected unauthorized")
        } catch RelayError.unauthorized {
            // ok
        }
    }

    /// Mirrors a real `tailscale debug localapi /v0/whois?addr=...` response
    /// shape so the parser stays honest if Tailscale renames fields.
    func testWhoisResponseParserMapsTailscaleShape() throws {
        let json = #"""
        {
          "Node": {
            "ID": 12345,
            "Name": "iphone15.tailnet.ts.net.",
            "Key": "nodekey:abc123def",
            "Hostinfo": {
              "OS": "iOS",
              "Hostname": "iPhone-15-Pro",
              "OSVersion": "17.4"
            }
          },
          "UserProfile": {
            "ID": 6789,
            "LoginName": "alice@example.com",
            "DisplayName": "Alice"
          }
        }
        """#
        let p = try TailscaledLocalAuth.parseWhoisResponse(Data(json.utf8))
        XCTAssertEqual(p.loginName, "alice@example.com")
        XCTAssertEqual(p.hostname, "iPhone-15-Pro")
        XCTAssertEqual(p.os, "iOS")
        XCTAssertEqual(p.nodeKey, "nodekey:abc123def")
    }

    func testWhoisResponseParserHandlesMissingHostinfo() throws {
        let json = #"""
        {
          "Node": { "ID": 1, "Name": "n", "Key": "nk" },
          "UserProfile": { "LoginName": "x@y" }
        }
        """#
        let p = try TailscaledLocalAuth.parseWhoisResponse(Data(json.utf8))
        XCTAssertEqual(p.loginName, "x@y")
        XCTAssertEqual(p.nodeKey, "nk")
        XCTAssertEqual(p.hostname, "")
        XCTAssertEqual(p.os, "")
    }
}
