import Foundation
import SharedKit
import Testing
@testable import CmuxRemote

@Suite("ClaudeTranscriptTimelineTests")
struct ClaudeTranscriptTimelineTests {
    private typealias F = TranscriptFixtures

    @Test
    func testOlderPagesPrependInOrderWithoutDuplicatesUntilStart() {
        var timeline = ClaudeTranscriptTimeline()
        timeline.replaceWithLatest(F.rows(F.users(["e4", "e5", "e6"])), before: 300)
        #expect(timeline.olderBefore == 300)
        #expect(!timeline.reachedStart)

        let anchor = timeline.prependOlder(F.rows(F.users(["e2", "e3", "e4"])), before: 100)
        #expect(timeline.rows.map(\.id) == ["e2", "e3", "e4", "e5", "e6"])
        #expect(anchor == "e4")
        #expect(timeline.olderBefore == 100)
        #expect(!timeline.reachedStart)

        timeline.prependOlder(F.rows(F.users(["e1"])), before: nil)
        #expect(timeline.rows.map(\.id) == ["e1", "e2", "e3", "e4", "e5", "e6"])
        #expect(timeline.olderBefore == nil)
        #expect(timeline.reachedStart)
        #expect(!timeline.newerTrimmed)
    }

    @Test
    func testFirstPageWithoutBeforeIsTheWholeTranscript() {
        var timeline = ClaudeTranscriptTimeline()
        #expect(!timeline.reachedStart)
        timeline.replaceWithLatest(F.rows(F.users(["e1", "e2"])), before: nil)
        #expect(timeline.reachedStart)
        #expect(timeline.olderBefore == nil)
    }

    @Test
    func testNeighborAssistantEntriesWithSameMessageIdMerge() {
        var timeline = ClaudeTranscriptTimeline()
        timeline.replaceWithLatest(F.rows([
            F.assistant("a1", messageId: "m1"),
            F.toolUse("a2", messageId: "m1"),
            F.user("u3"),
            F.assistant("a4", messageId: "m1"),
            F.assistant("a5", messageId: "m2"),
            F.assistant("a6"),
            F.assistant("a7"),
        ]), before: nil)
        #expect(timeline.rows.map(\.id) == ["a1", "u3", "a4", "a5", "a6", "a7"])
        #expect(timeline.rows[0].blocks.map(\.block.kind) == [.text, .toolUse])
        #expect(timeline.rows[0].blocks[0].markdown?.isEmpty == false)
        #expect(timeline.rows[0].blocks[1].markdown == nil)
    }

    @Test
    func testMessageSplitAcrossPagesMergesIntoTheVisibleRow() {
        var timeline = ClaudeTranscriptTimeline()
        timeline.replaceWithLatest(F.rows([F.toolUse("a2", messageId: "m1"), F.user("u3")]), before: 100)

        let anchor = timeline.prependOlder(F.rows([F.user("u0"), F.assistant("a1", messageId: "m1")]), before: nil)

        #expect(timeline.rows.map(\.id) == ["u0", "a2", "u3"])
        #expect(timeline.rows[1].blocks.map(\.block.kind) == [.text, .toolUse])
        #expect(anchor == "a2")
    }

    @Test
    func testRowCapTrimsNewestAndFlagsNewerTrimmed() {
        #expect(ClaudeTranscriptTimeline.maxRows == 600)
        #expect(ClaudeTranscriptTimeline.maxTextBytes == 4 * 1_024 * 1_024)

        var timeline = ClaudeTranscriptTimeline(maxRows: 4)
        timeline.replaceWithLatest(F.rows(F.users(["e5", "e6", "e7"])), before: 400)
        let anchor = timeline.prependOlder(F.rows(F.users(["e2", "e3", "e4"])), before: 100)

        #expect(timeline.rows.map(\.id) == ["e2", "e3", "e4", "e5"])
        #expect(timeline.newerTrimmed)
        #expect(anchor == "e5")
        #expect(timeline.olderBefore == 100)
    }

    @Test
    func testTextCapTrimsNewestRows() {
        var timeline = ClaudeTranscriptTimeline(maxTextBytes: 25)
        let tenBytes = String(repeating: "x", count: 10)
        timeline.replaceWithLatest(F.rows([F.user("e3", text: tenBytes), F.user("e4", text: tenBytes)]), before: 200)
        #expect(!timeline.newerTrimmed)

        timeline.prependOlder(F.rows([F.user("e2", text: tenBytes)]), before: 100)

        #expect(timeline.rows.map(\.id) == ["e2", "e3"])
        #expect(timeline.textBytes == 20)
        #expect(timeline.newerTrimmed)
    }

    @Test
    func testLatestPageAppendsNewRowsAndGrowsTheLastMessage() {
        var timeline = ClaudeTranscriptTimeline()
        timeline.replaceWithLatest(F.rows([F.user("u1"), F.assistant("a2", messageId: "m1")]), before: 100)

        let page = F.rows([F.user("u1"), F.assistant("a2", messageId: "m1"), F.toolUse("a3", messageId: "m1"), F.user("u4")])
        #expect(timeline.applyLatest(page, before: 100) == .appended)
        #expect(timeline.rows.map(\.id) == ["u1", "a2", "u4"])
        #expect(timeline.rows[1].blocks.count == 2)
        #expect(timeline.olderBefore == 100)

        #expect(timeline.applyLatest(page, before: 100) == .unchanged)
        #expect(timeline.rows.map(\.id) == ["u1", "a2", "u4"])
    }

    @Test
    func testLatestPageWithoutOverlapOrAfterTrimmingReplaces() {
        var timeline = ClaudeTranscriptTimeline()
        timeline.replaceWithLatest(F.rows(F.users(["e1", "e2"])), before: 100)
        #expect(timeline.applyLatest(F.rows(F.users(["e10", "e11"])), before: 900) == .replaced)
        #expect(timeline.rows.map(\.id) == ["e10", "e11"])
        #expect(timeline.olderBefore == 900)

        var trimmed = ClaudeTranscriptTimeline(maxRows: 2)
        trimmed.replaceWithLatest(F.rows(F.users(["e3", "e4"])), before: 200)
        trimmed.prependOlder(F.rows(F.users(["e2"])), before: 100)
        #expect(trimmed.newerTrimmed)
        #expect(trimmed.applyLatest(F.rows(F.users(["e3", "e4"])), before: 200) == .replaced)
        #expect(trimmed.rows.map(\.id) == ["e3", "e4"])
        #expect(!trimmed.newerTrimmed)
    }
}
