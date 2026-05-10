import XCTest
@testable import RelayCore
import SharedKit

final class CmuxConnectionTests: XCTestCase {
    func testBootIdChangeFiresReset() {
        var resets = 0
        let conn = CmuxConnection.makeForTesting()
        conn.onReset = { resets += 1 }
        conn.observe(bootInfo: BootInfo(bootId: "a", startedAt: 1))
        conn.observe(bootInfo: BootInfo(bootId: "a", startedAt: 1))
        XCTAssertEqual(resets, 0, "same boot id should not fire reset")
        conn.observe(bootInfo: BootInfo(bootId: "b", startedAt: 2))
        XCTAssertEqual(resets, 1, "first boot id change fires reset")
        conn.observe(bootInfo: BootInfo(bootId: "b", startedAt: 2))
        XCTAssertEqual(resets, 1, "stable boot id after change does not re-fire")
        conn.observe(bootInfo: BootInfo(bootId: "c", startedAt: 3))
        XCTAssertEqual(resets, 2, "next change fires again")
    }

    func testFirstObservationDoesNotFireReset() {
        var resets = 0
        let conn = CmuxConnection.makeForTesting()
        conn.onReset = { resets += 1 }
        conn.observe(bootInfo: BootInfo(bootId: "first", startedAt: 1))
        XCTAssertEqual(resets, 0,
                       "no prior boot id, so the first observation cannot be a 'change'")
    }
}
