import Darwin
import Foundation
import SharedKit
import Testing
@testable import RelayServer

@Suite("ClaudeTranscriptReaderTests")
struct ClaudeTranscriptReaderTests {
    @Test func fixturePagesFromEndToStartWithoutOverlapOrGap() throws {
        let url = try TranscriptFixture.url()
        let full = try readTranscriptPage(url)
        #expect(full.page.before == nil)
        #expect(full.page.entries.map(\.id) == ["u1", "a2", "u2", "a3", "u3", "a4"])

        for maxEntries in [1, 2, 4] {
            let pages = try readAllTranscriptPages(url, maxEntries: maxEntries)
            let stitched = pages.reversed().flatMap(\.entries)
            #expect(stitched == full.page.entries)
            #expect(pages.allSatisfy { $0.entries.count <= maxEntries })
            #expect(pages.count == (6 + maxEntries - 1) / maxEntries)
        }
    }

    @Test func fiveMiBLineIsSkippedWithoutHoldingIt() throws {
        let sandbox = try TranscriptSandbox()
        defer { sandbox.remove() }
        let url = try sandbox.write(sandbox.project.appendingPathComponent("huge.jsonl"), [
            TranscriptLine.user("first", "before the long line"),
            TranscriptLine.user("huge", String(repeating: "x", count: 5 * 1_024 * 1_024)),
            TranscriptLine.user("last", "after the long line"),
        ])

        let page = try readTranscriptPage(url).page

        #expect(page.entries.map(\.id) == ["first", "last"])
        #expect(page.scan.skippedLongLines == 1)
        #expect(page.scan.peakHeldBytes <= ClaudeTranscriptLimits.maxLineBytes)
        #expect(page.before == nil)
    }

    @Test func incompleteLastLineIsHiddenUntilCompleted() throws {
        let sandbox = try TranscriptSandbox()
        defer { sandbox.remove() }
        let url = sandbox.project.appendingPathComponent("live.jsonl")
        let finished = TranscriptLine.user("done", "complete line")
        let writing = TranscriptLine.user("writing", "still being written")
        try sandbox.write(url, [finished, writing.prefix(writing.count - 12)])

        let partial = try readTranscriptPage(url).page
        #expect(partial.entries.map(\.id) == ["done"])
        #expect(partial.brokenLines == 0)

        try sandbox.write(url, [finished, writing])
        let completed = try readTranscriptPage(url).page
        #expect(completed.entries.map(\.id) == ["done", "writing"])
    }

    @Test func brokenLineIsSkipped() throws {
        let sandbox = try TranscriptSandbox()
        defer { sandbox.remove() }
        let url = try sandbox.write(sandbox.project.appendingPathComponent("broken.jsonl"), [
            TranscriptLine.user("before", "a"),
            Data("{not json at all\n".utf8),
            Data("[1, 2, 3]\n".utf8),
            TranscriptLine.user("after", "b"),
        ])

        let page = try readTranscriptPage(url).page

        #expect(page.entries.map(\.id) == ["before", "after"])
        #expect(page.brokenLines == 2)
    }

    @Test func neighboringAssistantLinesWithOneMessageIdMerge() throws {
        let sandbox = try TranscriptSandbox()
        defer { sandbox.remove() }
        let url = try sandbox.write(sandbox.project.appendingPathComponent("merge.jsonl"), [
            TranscriptLine.user("u", "go"),
            TranscriptLine.assistant("a-think", messageId: "m1", [["type": "thinking", "thinking": "hidden", "signature": "s"]]),
            TranscriptLine.assistant("a-text", messageId: "m1", [["type": "text", "text": "Reading"]]),
            TranscriptLine.json(["type": "attachment", "attachment": ["content": "between"]]),
            TranscriptLine.assistant("a-tool", messageId: "m1", [["type": "tool_use", "id": "t", "name": "Bash", "input": ["command": "ls"]]]),
            TranscriptLine.assistant("b-text", messageId: "m2", [["type": "text", "text": "Done"]]),
        ])

        let entries = try readTranscriptPage(url).page.entries

        #expect(entries.map(\.id) == ["u", "a-text", "b-text"])
        #expect(entries[1].messageId == "m1")
        #expect(entries[1].blocks.map(\.kind) == [.text, .toolUse])
        #expect(entries[2].messageId == "m2")
    }

    @Test func pageCountStopsAtANewEntryButKeepsMergingOneMessage() throws {
        let sandbox = try TranscriptSandbox()
        defer { sandbox.remove() }
        let url = try sandbox.write(sandbox.project.appendingPathComponent("stop.jsonl"), [
            TranscriptLine.user("older", "q"),
            TranscriptLine.assistant("a1", messageId: "m", [["type": "text", "text": "one"]]),
            TranscriptLine.assistant("a2", messageId: "m", [["type": "text", "text": "two"]]),
        ])

        let first = try readTranscriptPage(url, maxEntries: 1)
        #expect(first.page.entries.map(\.id) == ["a1"])
        #expect(first.page.entries[0].blocks.compactMap(\.text) == ["one", "two"])
        let older = try readTranscriptPage(url, before: try #require(first.page.before), maxEntries: 1).page
        #expect(older.entries.map(\.id) == ["older"])
        #expect(older.before == nil)
    }

    @Test func sixtyMiBFileReadsOnePageWithinScanBudget() throws {
        let sandbox = try TranscriptSandbox()
        defer { sandbox.remove() }
        let url = sandbox.project.appendingPathComponent("large.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: TranscriptLine.user("oldest", "start"))
        let filler = TranscriptLine.json(["type": "attachment", "attachment": ["content": String(repeating: "a", count: 1_024 * 1_024)]])
        for _ in 0..<60 { try handle.write(contentsOf: filler) }
        try handle.write(contentsOf: TranscriptLine.user("newest", "end"))
        try handle.close()
        let readCap = ClaudeTranscriptLimits.maxScanBytesPerRequest + ClaudeTranscriptLimits.readBlockBytes

        let clock = ContinuousClock()
        var first: (page: ClaudeTranscriptReader.Page, size: Int64)?
        let firstDuration = try clock.measure { first = try readTranscriptPage(url) }
        let page = try #require(first)
        #expect(page.size >= 60 * 1_024 * 1_024)
        #expect(page.page.entries.map(\.id) == ["newest"])
        #expect(page.page.scan.bytesRead <= readCap)
        let before = try #require(page.page.before)
        #expect(before < page.size)

        let pages = try readAllTranscriptPages(url, maxEntries: ClaudeTranscriptLimits.defaultPageEntries)
        #expect(pages.reversed().flatMap(\.entries).map(\.id) == ["oldest", "newest"])
        #expect(pages.allSatisfy { $0.scan.bytesRead <= readCap })
        print("CLAUDE_READ_BENCH file_bytes=\(page.size) first_page_bytes_read=\(page.page.scan.bytesRead) first_page=\(firstDuration) pages=\(pages.count) max_bytes_read=\(pages.map(\.scan.bytesRead).max() ?? 0)")
    }
}
