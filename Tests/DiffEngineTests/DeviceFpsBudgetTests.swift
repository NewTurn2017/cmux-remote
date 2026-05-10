import XCTest
@testable import RelayCore

final class DeviceFpsBudgetTests: XCTestCase {
    func testAllowsUntilCap() {
        let clock = FakeClock()
        let budget = DeviceFpsBudget(maxPerSecond: 5, clock: clock)
        for _ in 0..<5 { XCTAssertTrue(budget.consumeFrame()) }
        XCTAssertFalse(budget.consumeFrame())
    }

    func testWindowSlides() {
        let clock = FakeClock()
        let budget = DeviceFpsBudget(maxPerSecond: 2, clock: clock)
        XCTAssertTrue(budget.consumeFrame())
        XCTAssertTrue(budget.consumeFrame())
        XCTAssertFalse(budget.consumeFrame())
        clock.advance(by: 1.001)
        XCTAssertTrue(budget.consumeFrame())
    }
}
