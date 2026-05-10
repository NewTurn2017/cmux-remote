import XCTest
@testable import RelayCore

final class RateLimiterTests: XCTestCase {
    func testHonorsBucketLimit() {
        let clock = FakeClock()
        let lim = PerDeviceRateLimiter(clock: clock)
        for _ in 0..<100 { XCTAssertTrue(lim.allow(deviceId: "a", method: "surface.send_text")) }
        XCTAssertFalse(lim.allow(deviceId: "a", method: "surface.send_text"))
    }

    func testIndependentMethodBuckets() {
        let lim = PerDeviceRateLimiter()
        for _ in 0..<100 { _ = lim.allow(deviceId: "a", method: "surface.send_text") }
        XCTAssertTrue(lim.allow(deviceId: "a", method: "surface.send_key"))
    }

    func testWindowSlides() {
        let clock = FakeClock()
        let lim = PerDeviceRateLimiter(clock: clock)
        for _ in 0..<100 { _ = lim.allow(deviceId: "a", method: "surface.send_text") }
        clock.advance(by: 1.001)
        XCTAssertTrue(lim.allow(deviceId: "a", method: "surface.send_text"))
    }

    func testIndependentDeviceBuckets() {
        let lim = PerDeviceRateLimiter()
        for _ in 0..<100 { _ = lim.allow(deviceId: "a", method: "surface.send_text") }
        XCTAssertTrue(lim.allow(deviceId: "b", method: "surface.send_text"))
    }

    func testUnknownMethodIsUnlimited() {
        let lim = PerDeviceRateLimiter()
        for _ in 0..<10000 {
            XCTAssertTrue(lim.allow(deviceId: "a", method: "workspace.list"))
        }
    }
}
