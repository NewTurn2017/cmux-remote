import XCTest
@testable import CmuxRemote

final class AppVersionInfoTests: XCTestCase {
    func testDisplayTextCombinesMarketingVersionAndBuild() {
        let info = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "2.0.0",
            "CFBundleVersion": "22",
        ])
        XCTAssertEqual(info.displayText, "2.0.0 (22)")
    }

    func testMissingBundleValuesShowPlaceholders() {
        XCTAssertEqual(AppVersionInfo(infoDictionary: nil).displayText, "? (?)")
    }

    func testRunningAppReportsVersionTwoBuildTwentyTwo() {
        XCTAssertEqual(AppVersionInfo.current.displayText, "2.0.0 (22)")
    }

    func testSemanticVersionComparesNumericallyAndPadsMissingParts() throws {
        let tenth = try XCTUnwrap(SemanticVersion("1.10.0"))
        let ninth = try XCTUnwrap(SemanticVersion("1.9.9"))
        XCTAssertGreaterThan(tenth, ninth)
        XCTAssertEqual(SemanticVersion("2"), SemanticVersion("2.0.0"))
        XCTAssertEqual(SemanticVersion("2.1"), SemanticVersion("2.1.0"))
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("2.0.0")), try XCTUnwrap(SemanticVersion("2.0.1")))
    }

    func testSemanticVersionRejectsNonNumericOrOverlongInput() {
        for text in ["", "2.0.0-beta", "v2.0.0", "2..0", "2.0.0.1", "２.0.0", "-1.0.0", " 2.0.0"] {
            XCTAssertNil(SemanticVersion(text), text)
        }
    }
}
