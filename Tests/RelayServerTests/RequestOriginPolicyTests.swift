import NIOHTTP1
import XCTest
@testable import RelayServer

final class RequestOriginPolicyTests: XCTestCase {
    private func headers(host: String?, origin: String? = nil) -> HTTPHeaders {
        var headers = HTTPHeaders()
        if let host { headers.add(name: "Host", value: host) }
        if let origin { headers.add(name: "Origin", value: origin) }
        return headers
    }

    func testNativeClientHostsAreAllowed() {
        for host in [
            "100.115.102.6:4399", "100.64.0.1", "127.0.0.1:4399", "localhost:4399",
            "[fd7a:115c:a1e0::1]:4399", "mac.tail1234.ts.net:4399", "Mac.Tail1234.TS.NET.:4399",
            "genie-mac:4399",
        ] {
            XCTAssertTrue(RequestOriginPolicy.allows(headers(host: host)), host)
        }
        XCTAssertTrue(RequestOriginPolicy.allows(headers(host: nil)))
    }

    func testRebindableHostnamesAreRejected() {
        for host in ["evil.example:4399", "attacker.com", "100.115.102.6.nip.io:4399", "1.2.3.4.5", "", "[fd7a::1"] {
            XCTAssertFalse(RequestOriginPolicy.allows(headers(host: host)), host)
        }
    }

    func testCrossSiteOriginIsRejected() {
        XCTAssertFalse(RequestOriginPolicy.allows(
            headers(host: "100.115.102.6:4399", origin: "https://evil.example")
        ))
        XCTAssertFalse(RequestOriginPolicy.allows(headers(host: "100.115.102.6:4399", origin: "null")))
        XCTAssertFalse(RequestOriginPolicy.allows(headers(host: nil, origin: "http://100.115.102.6:4399")))
    }

    func testSameOriginBrowserIsAllowed() {
        XCTAssertTrue(RequestOriginPolicy.allows(
            headers(host: "100.115.102.6:4399", origin: "http://100.115.102.6:4399")
        ))
        XCTAssertFalse(RequestOriginPolicy.allows(
            headers(host: "100.115.102.6:4399", origin: "http://100.115.102.6:8080")
        ))
    }
}
