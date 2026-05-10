import XCTest
@testable import RelayCore

final class DeviceFpsBudgetTests: XCTestCase {
    func testAllowsUntilCap() async {
        let clock = FakeClock()
        let budget = DeviceFpsBudget(maxPerSecond: 5, clock: clock)
        for _ in 0..<5 {
            let ok = await budget.consumeFrame()
            XCTAssertTrue(ok)
        }
        let blocked = await budget.consumeFrame()
        XCTAssertFalse(blocked)
    }

    func testWindowSlides() async {
        let clock = FakeClock()
        let budget = DeviceFpsBudget(maxPerSecond: 2, clock: clock)
        let r1 = await budget.consumeFrame(); XCTAssertTrue(r1)
        let r2 = await budget.consumeFrame(); XCTAssertTrue(r2)
        let r3 = await budget.consumeFrame(); XCTAssertFalse(r3)
        clock.advance(by: 1.001)
        let r4 = await budget.consumeFrame(); XCTAssertTrue(r4)
    }
}
