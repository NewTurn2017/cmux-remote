import Foundation
import SharedKit
import Testing
@testable import RelayServer

@Suite("ClaudeTranscriptRendererTests")
struct ClaudeTranscriptRendererTests {
    private func entry(_ line: Data) throws -> ClaudeTranscriptEntry {
        guard case .entry(let entry) = ClaudeTranscriptRenderer.render(line) else {
            throw CocoaError(.coderValueNotFound)
        }
        return entry
    }

    private func toolUse(_ name: String, _ input: [String: Any]) throws -> ClaudeTranscriptBlock {
        try entry(TranscriptLine.assistant("a", messageId: "m", [["type": "tool_use", "id": "t", "name": name, "input": input]])).blocks[0]
    }

    @Test func fixtureProducesSixEntriesAndExcludesThinkingSidechainAttachmentApiRequestSystem() throws {
        let entries = try readTranscriptPage(try TranscriptFixture.url()).page.entries

        #expect(entries.map(\.role) == [.user, .assistant, .user, .assistant, .user, .assistant])
        #expect(entries[0].blocks == [ClaudeTranscriptBlock(kind: .text, text: "README의 설치 절차를 짧게 정리해줘.")])
        #expect(entries[0].timestamp == 1_794_182_401_000)
        #expect(entries[0].messageId == nil)
        #expect(entries[1].messageId == "msg_1")
        #expect(entries[1].blocks == [ClaudeTranscriptBlock(kind: .toolUse, toolName: "Read", summary: "/Users/example/dev/demo/README.md")])
        #expect(entries[2].blocks.map(\.kind) == [.toolResult])
        #expect(entries[2].blocks[0].summary?.hasPrefix("# Demo\n\n설치: brew install demo") == true)
        #expect(entries[3].blocks.first?.text?.hasPrefix("정리했습니다.") == true)
        #expect(entries[4].blocks.first?.text == "고마워. 이모지도 되나? 🙂 한글과 \"따옴표\"\\역슬래시 확인.")
        #expect(entries[5].blocks == [
            ClaudeTranscriptBlock(kind: .toolUse, toolName: "web_search", summary: "demo"),
            ClaudeTranscriptBlock(kind: .text, text: "네, 됩니다 🙂"),
        ])
        #expect(entries[5].timestamp == 1_794_182_462_000)

        let encoded = String(decoding: try SharedKitJSON.snakeCaseEncoder.encode(entries), as: UTF8.self)
        for hidden in ["생각 내용", "sig", "서브", "훅 문맥", "시스템 알림", "XXXXXXXX", "not json", "lastPrompt", "permission"] {
            #expect(!encoded.contains(hidden), "\(hidden)")
        }
        let decoded = try SharedKitJSON.snakeCaseDecoder.decode([ClaudeTranscriptEntry].self, from: Data(encoded.utf8))
        #expect(decoded == entries)
    }

    @Test func toolInputSummaryRules() throws {
        #expect(try toolUse("Bash", ["command": "git status\n  && ls", "description": "x"]).summary == "git status   && ls")
        #expect(try toolUse("Edit", ["file_path": "/a/b.swift", "old_string": "x"]).summary == "/a/b.swift")
        #expect(try toolUse("NotebookEdit", ["notebook_path": "/n.ipynb"]).summary == "/n.ipynb")
        #expect(try toolUse("Grep", ["pattern": "TODO", "path": "Sources"]).summary == "TODO in Sources")
        #expect(try toolUse("Glob", ["pattern": "**/*.swift"]).summary == "**/*.swift")
        #expect(try toolUse("WebFetch", ["url": "https://example.com"]).summary == "https://example.com")
        #expect(try toolUse("Task", ["description": "Explore", "prompt": "long"]).summary == "Explore")
        #expect(try toolUse("TodoWrite", ["todos": [["content": "a"], ["content": "b"]]]).summary == "2 todos")
        #expect(try toolUse("mcp__x__y", ["zeta": "last", "alpha": "first", "count": 3]).summary == "first")
        #expect(try toolUse("Unknown", ["count": 3]).summary == nil)

        let long = try toolUse("Bash", ["command": String(repeating: "가", count: 600)])
        #expect(long.summary?.count == ClaudeTranscriptLimits.maxToolUseSummaryCharacters)
        #expect(long.truncated == true)
    }

    @Test func toolResultArrayWithImageBlock() throws {
        let rendered = try entry(TranscriptLine.json([
            "type": "user", "uuid": "r",
            "message": ["role": "user", "content": [[
                "type": "tool_result", "tool_use_id": "t", "is_error": true,
                "content": [["type": "text", "text": "first"], ["type": "image", "source": ["data": "AAAA"]], ["type": "text", "text": "second"]],
            ]]],
        ]))
        #expect(rendered.blocks == [ClaudeTranscriptBlock(kind: .toolResult, summary: "first\n[image]\nsecond", isError: true)])

        let longResult = try entry(TranscriptLine.json([
            "type": "user", "uuid": "r2",
            "message": ["role": "user", "content": [["type": "tool_result", "content": String(repeating: "결", count: 2_000)]]],
        ])).blocks[0]
        #expect(longResult.summary?.utf8.count ?? 0 <= ClaudeTranscriptLimits.maxToolResultSummaryBytes)
        #expect(longResult.truncated == true)
        #expect(longResult.isError == nil)
    }

    @Test func linesOutsideTheMainConversationAreSkipped() {
        #expect(ClaudeTranscriptRenderer.render(TranscriptLine.user("s", "side", extra: ["isSidechain": true])) == .skipped)
        #expect(ClaudeTranscriptRenderer.render(TranscriptLine.user("m", "meta", extra: ["isMeta": true])) == .skipped)
        #expect(ClaudeTranscriptRenderer.render(TranscriptLine.assistant("t", messageId: "m", [
            ["type": "thinking", "thinking": "x", "signature": "s"], ["type": "redacted_thinking", "data": "y"],
        ])) == .skipped)
        #expect(ClaudeTranscriptRenderer.render(TranscriptLine.json(["type": "system", "uuid": "x", "content": "x"])) == .skipped)
        #expect(ClaudeTranscriptRenderer.render(TranscriptLine.json(["type": "user", "message": ["content": "no uuid"]])) == .skipped)
        #expect(ClaudeTranscriptRenderer.render(Data("{\"type\": \"user\", ".utf8)) == .broken)
    }

    @Test func longTextIsCutAndEveryEntryFitsItsCap() throws {
        let cut = try entry(TranscriptLine.user("long", String(repeating: "가", count: 20_000))).blocks[0]
        #expect(cut.text?.utf8.count ?? 0 <= ClaudeTranscriptLimits.maxTextBytes)
        #expect(cut.truncated == true)

        let escaped = try entry(TranscriptLine.user("ctl", String(repeating: "\u{01}", count: ClaudeTranscriptLimits.maxTextBytes)))
        #expect(ClaudeTranscriptRenderer.encodedSize(escaped) <= ClaudeTranscriptRenderer.maxEntryBytes)
        #expect(escaped.blocks[0].truncated == true)

        let manyBlocks = (0..<40).map { ["type": "text", "text": "block \($0) " + String(repeating: "\"", count: 4_000)] as [String: Any] }
        let wide = try entry(TranscriptLine.assistant("wide", messageId: "m", manyBlocks))
        #expect(wide.blocks.count <= ClaudeTranscriptLimits.maxBlocksPerEntry)
        #expect(wide.blocks.last?.truncated == true)
        #expect(ClaudeTranscriptRenderer.encodedSize(wide) <= ClaudeTranscriptRenderer.maxEntryBytes)
        for value in [escaped, wide] {
            let data = try SharedKitJSON.snakeCaseEncoder.encode(value)
            #expect(try SharedKitJSON.snakeCaseDecoder.decode(ClaudeTranscriptEntry.self, from: data) == value)
        }
    }
}
