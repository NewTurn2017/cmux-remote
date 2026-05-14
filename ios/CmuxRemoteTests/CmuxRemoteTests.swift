import XCTest
@testable import CmuxRemote
import SharedKit

final class SmokeTests: XCTestCase {
    func testSharedKitLinks() {
        let request = RPCRequest(id: "test-1", method: "x", params: .null)
        XCTAssertEqual(request.id, "test-1")
    }
}
