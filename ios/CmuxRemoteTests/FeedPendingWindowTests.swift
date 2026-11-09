import Foundation
import SharedKit
import Testing
@testable import CmuxRemote

@Suite("FeedPendingWindowTests")
struct FeedPendingWindowTests {
    private let now = BrowserFixtures.fixedNow

    private func remaining(afterSeconds age: Double) -> Int? {
        FeedPendingWindow.remainingSeconds(createdAt: FeedFixtures.createdAt(secondsBefore: now, age), now: now)
    }

    private func numbers(in text: String) -> [Int] {
        text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    @Test
    func testRemainingSecondsAcrossValues() {
        #expect(FeedPendingWindow.expectedSeconds == 115)
        #expect(remaining(afterSeconds: 0) == 115)
        #expect(remaining(afterSeconds: 25) == 90)
        #expect(remaining(afterSeconds: 55) == 60)
        #expect(remaining(afterSeconds: 100.5) == 15)
        #expect(remaining(afterSeconds: -20) == 115)
        #expect(FeedPendingWindow.remainingSeconds(createdAt: nil, now: now) == nil)
    }

    @Test
    func testRemainingTextShowsMinutesAndSeconds() {
        #expect(numbers(in: FeedPendingWindow.remainingText(seconds: 90)) == [1, 30])
        #expect(numbers(in: FeedPendingWindow.remainingText(seconds: 60)) == [1])
        #expect(numbers(in: FeedPendingWindow.remainingText(seconds: 115)) == [1, 55])
        #expect(numbers(in: FeedPendingWindow.remainingText(seconds: 45)) == [45])
        #expect(FeedPendingWindow.remainingText(seconds: 45) != FeedPendingWindow.remainingText(seconds: 60))
    }

    @Test
    func testUrgentFromThirtySecondsDown() {
        #expect(!FeedPendingWindow.isUrgent(remainingSeconds: 31))
        #expect(FeedPendingWindow.isUrgent(remainingSeconds: 30))
        #expect(FeedPendingWindow.isUrgent(remainingSeconds: 1))
        #expect(!FeedPendingWindow.isUrgent(remainingSeconds: 0))
        #expect(remaining(afterSeconds: 84) == 31)
        #expect(remaining(afterSeconds: 85) == 30)
    }

    @Test
    func testItemExpiresWhenNoTimeIsLeft() {
        let almost = FeedFixtures.permission(createdAt: FeedFixtures.createdAt(secondsBefore: now, 114.9))
        let expired = FeedFixtures.permission(createdAt: FeedFixtures.createdAt(secondsBefore: now, 115))
        let unknown = FeedFixtures.permission(createdAt: nil)
        #expect(!FeedPendingWindow.isExpired(almost, now: now))
        #expect(FeedPendingWindow.isExpired(expired, now: now))
        #expect(remaining(afterSeconds: 300) == 0)
        #expect(!FeedPendingWindow.isExpired(unknown, now: now))
    }

    @Test
    func testDepartedReasonFollowsAgeAndCardLastsTenSeconds() {
        let old = FeedFixtures.permission(createdAt: FeedFixtures.createdAt(secondsBefore: now, 110))
        let young = FeedFixtures.permission(createdAt: FeedFixtures.createdAt(secondsBefore: now, 109))
        #expect(FeedDepartedItem.reason(for: old, now: now) == .expired)
        #expect(FeedDepartedItem.reason(for: young, now: now) == .handledElsewhere)
        #expect(FeedDepartedItem.reason(for: FeedFixtures.permission(createdAt: nil), now: now) == .handledElsewhere)

        let departed = FeedDepartedItem(item: old, reason: .expired, departedAt: now)
        #expect(departed.isVisible(at: now.addingTimeInterval(9.9)))
        #expect(!departed.isVisible(at: now.addingTimeInterval(10)))
    }
}
