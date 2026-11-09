import Foundation
import SharedKit

/// Synthetic Claude sessions and transcripts for UI-test fixture mode. All text is invented.
///
/// Each transcript has ``entryCount`` entries served ``pageSize`` at a time, newest page first.
/// Entry `n` sits at byte `n * bytesPerEntry`, so `before` cursors are exact multiples.
/// Every turn is a question, Claude's text, a tool call with the same message id, and the tool
/// result; a page boundary splits turn 8, so loading the older page merges Claude's message.
enum DemoClaudeTranscriptFixtures {
    static let liveSessionID = "demo-claude-live"
    static let idleSessionID = "demo-claude-idle"
    static let exitedSessionID = "demo-claude-exited"
    static let missingSessionID = "demo-claude-missing"
    static let entryCount = 45
    static let pageSize = 15
    static let bytesPerEntry: Int64 = 1_000

    static func sessions(nowMilliseconds now: Int64) -> [ClaudeSessionSummary] {
        let minute: Int64 = 60_000
        return [
            ClaudeSessionSummary(
                sessionId: liveSessionID,
                title: "Cache the feed list for one second",
                cwd: "/Users/demo/dev/agent-lab",
                gitBranch: "feat/feed-cache",
                status: "live",
                createdAt: now - 95 * minute,
                modifiedAt: now - minute / 2
            ),
            ClaudeSessionSummary(
                sessionId: idleSessionID,
                title: "README 설치 절차 정리",
                cwd: "/Users/demo/dev/notes-api",
                gitBranch: "main",
                status: "idle",
                createdAt: now - 300 * minute,
                modifiedAt: now - 12 * minute
            ),
            ClaudeSessionSummary(
                sessionId: exitedSessionID,
                title: "Fix the release checklist",
                cwd: "/Users/demo/dev/site",
                status: "exited",
                createdAt: now - 26 * 60 * minute,
                modifiedAt: now - 3 * 60 * minute
            ),
            ClaudeSessionSummary(
                sessionId: missingSessionID,
                title: "Old experiment",
                cwd: "/Users/demo/dev/scratch",
                status: "exited",
                createdAt: now - 4 * 24 * 60 * minute,
                modifiedAt: now - 2 * 24 * 60 * minute
            ),
        ]
    }

    static func entryID(sessionID: String, index: Int) -> String {
        "\(prefix(sessionID))-e\(String(format: "%02d", index + 1))"
    }

    /// The page ending before `before` (exclusive byte offset), or the newest page.
    static func page(
        sessionID: String,
        before: Int64?,
        maxEntries: Int?,
        extraEntries: Int,
        nowMilliseconds now: Int64
    ) -> ClaudeTranscriptPageResult {
        let total = entryCount + extraEntries
        let end = before.map { Int($0 / bytesPerEntry) } ?? total
        let start = max(0, end - min(pageSize, maxEntries ?? pageSize))
        let baseTime = now - Int64(total) * 40_000
        return ClaudeTranscriptPageResult(
            sessionId: sessionID,
            entries: (start..<end).map { entry(sessionID: sessionID, index: $0, timestamp: baseTime + Int64($0) * 40_000) },
            before: start > 0 ? Int64(start) * bytesPerEntry : nil,
            fileSize: Int64(total) * bytesPerEntry
        )
    }

    private static func prefix(_ sessionID: String) -> String {
        sessionID.replacingOccurrences(of: "demo-claude-", with: "")
    }

    private static let tools: [(name: String, summary: String)] = [
        ("Read", "/Users/demo/dev/agent-lab/Sources/FeedCache.swift"),
        ("Bash", "swift test --filter FeedCacheTests"),
        ("Grep", "sharedTask in Sources/"),
        ("Edit", "/Users/demo/dev/agent-lab/Sources/FeedCache.swift"),
    ]

    private static func entry(sessionID: String, index: Int, timestamp: Int64) -> ClaudeTranscriptEntry {
        let turn = index / 4
        let id = entryID(sessionID: sessionID, index: index)
        let messageID = "\(prefix(sessionID))-msg-\(turn + 1)"
        let tool = tools[turn % tools.count]
        switch index % 4 {
        case 0:
            return ClaudeTranscriptEntry(id: id, role: .user, timestamp: timestamp, blocks: [
                ClaudeTranscriptBlock(kind: .text, text: "Turn \(turn + 1): check how the feed cache behaves and tell me what changed."),
            ])
        case 1:
            let truncated = turn == 5
            return ClaudeTranscriptEntry(id: id, role: .assistant, timestamp: timestamp, messageId: messageID, blocks: [
                ClaudeTranscriptBlock(
                    kind: .text,
                    text: """
                    ### Turn \(turn + 1)

                    I read `FeedCache.swift`. The list is kept for **one second** and callers share the request in flight.

                    - a reply clears the cache
                    - a failed list is not cached
                    """,
                    truncated: truncated ? true : nil
                ),
            ])
        case 2:
            return ClaudeTranscriptEntry(id: id, role: .assistant, timestamp: timestamp, messageId: messageID, blocks: [
                ClaudeTranscriptBlock(kind: .toolUse, toolName: tool.name, summary: tool.summary),
            ])
        default:
            let failed = turn == 3
            return ClaudeTranscriptEntry(id: id, role: .user, timestamp: timestamp, blocks: [
                ClaudeTranscriptBlock(
                    kind: .toolResult,
                    summary: failed
                        ? "error: no such file: Sources/FeedCach.swift\nDid you mean Sources/FeedCache.swift?"
                        : "Test Suite 'FeedCacheTests' passed\nExecuted 12 tests, with 0 failures in 0.041 seconds",
                    isError: failed ? true : nil
                ),
            ])
        }
    }
}
