import XCTest
import SharedKit
@testable import CmuxRemote

final class TerminalOverscrollPagingPolicyTests: XCTestCase {
    private typealias Policy = TerminalOverscrollPagingPolicy

    private func sample(
        screen: String? = "alternate",
        tracking: Bool = true,
        top: CGFloat = 0,
        bottom: CGFloat = 0,
        blocked: Bool = false,
        at time: TimeInterval = 0
    ) -> Policy.Sample {
        Policy.Sample(
            activeScreen: screen,
            isTracking: tracking,
            topOverscroll: top,
            bottomOverscroll: bottom,
            interactionBlocked: blocked,
            time: time
        )
    }

    func testPrimaryOrUnknownScreenNeverSendsKeys() {
        for screen in ["primary", nil] as [String?] {
            var policy = Policy()
            XCTAssertNil(policy.update(sample(screen: screen, top: 400)))
            XCTAssertNil(policy.update(sample(screen: screen, bottom: 400, at: 1)))
            XCTAssertEqual(policy.hint, .idle)
        }
    }

    func testAlternateTopPullSendsPageUpOncePerPull() {
        var policy = Policy()
        XCTAssertNil(policy.update(sample(top: 20)))
        XCTAssertEqual(policy.hint, .pulling(.top))
        XCTAssertEqual(policy.update(sample(top: Policy.threshold, at: 0.1)), .pageUp)
        XCTAssertEqual(policy.hint, .sent(.top))
        XCTAssertNil(policy.update(sample(top: 200, at: 0.5)))
        XCTAssertNil(policy.update(sample(top: 400, at: 2)))
        XCTAssertEqual(policy.hint, .sent(.top))
    }

    func testAlternateBottomPushSendsPageDownOncePerPull() {
        var policy = Policy()
        XCTAssertEqual(policy.update(sample(bottom: 60)), .pageDown)
        XCTAssertNil(policy.update(sample(bottom: 300, at: 1)))
    }

    func testOverscrollBelowThresholdSendsNothing() {
        var policy = Policy()
        XCTAssertNil(policy.update(sample(top: Policy.threshold - 1)))
        XCTAssertNil(policy.update(sample(bottom: Policy.threshold - 1, at: 0.1)))
    }

    func testReleaseRearmsButSameDirectionWaitsMinimumInterval() {
        var policy = Policy()
        XCTAssertEqual(policy.update(sample(top: 80, at: 0)), .pageUp)
        XCTAssertNil(policy.update(sample(tracking: false, top: 80, at: 0.1)))
        XCTAssertEqual(policy.hint, .idle)
        XCTAssertNil(policy.update(sample(top: 80, at: 0.2)))
        XCTAssertEqual(policy.update(sample(top: 80, at: Policy.minimumInterval)), .pageUp)
    }

    func testMinimumIntervalIsPerDirection() {
        var policy = Policy()
        XCTAssertEqual(policy.update(sample(top: 80, at: 0)), .pageUp)
        _ = policy.update(sample(tracking: false, at: 0.05))
        XCTAssertEqual(policy.update(sample(bottom: 80, at: 0.1)), .pageDown)
    }

    func testBounceAndProgrammaticScrollNeverSendKeys() {
        var policy = Policy()
        XCTAssertNil(policy.update(sample(tracking: false, top: 300)))
        XCTAssertNil(policy.update(sample(tracking: false, bottom: 300, at: 1)))
        XCTAssertEqual(policy.hint, .idle)
    }

    func testSelectionOrPinchBlocksPaging() {
        var policy = Policy()
        XCTAssertNil(policy.update(sample(top: 300, blocked: true)))
        XCTAssertEqual(policy.hint, .idle)
        XCTAssertEqual(policy.update(sample(top: 300, at: 1)), .pageUp)
    }

    func testOverscrollGeometryMeasuresPastEachEdge() {
        let pulledDown = Policy.overscroll(
            contentOffsetY: -100, contentHeight: 1_000, boundsHeight: 400, insetTop: 20, insetBottom: 0
        )
        XCTAssertEqual(pulledDown.top, 80)
        XCTAssertEqual(pulledDown.bottom, 0)

        let pushedUp = Policy.overscroll(
            contentOffsetY: 670, contentHeight: 1_000, boundsHeight: 400, insetTop: 0, insetBottom: 10
        )
        XCTAssertEqual(pushedUp.top, 0)
        XCTAssertEqual(pushedUp.bottom, 60)

        let shortContent = Policy.overscroll(
            contentOffsetY: 70, contentHeight: 100, boundsHeight: 400, insetTop: 0, insetBottom: 0
        )
        XCTAssertEqual(shortContent.bottom, 70)
    }
}
