import XCTest
import SharedKit
@testable import CmuxRemote

final class SurfaceKindTests: XCTestCase {
    func testKindsMapToSymbols() {
        XCTAssertEqual(SurfaceKind(type: "terminal").systemImage, "terminal")
        XCTAssertEqual(SurfaceKind(type: nil).systemImage, "terminal")
        XCTAssertEqual(SurfaceKind(type: "browser").systemImage, "globe")
        XCTAssertEqual(SurfaceKind(type: "markdown").systemImage, "doc.richtext")
        XCTAssertEqual(SurfaceKind(type: "pdf"), .other)
        XCTAssertEqual(SurfaceKind(type: "pdf").systemImage, "doc")
    }

    func testSurfaceKindFollowsSurfaceType() {
        XCTAssertEqual(SurfaceKind(Surface(id: "b", title: "web", index: 0, type: "browser")), .browser)
        XCTAssertEqual(SurfaceKind(Surface(id: "t", title: "sh", index: 0)), .terminal)
    }
}
