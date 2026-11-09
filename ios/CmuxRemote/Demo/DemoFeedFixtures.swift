import Foundation
import SharedKit

/// Synthetic pending feed requests for UI-test fixture mode. All text is invented.
enum DemoFeedFixtures {
    static let permissionRequestID = "demo-feed-permission"
    static let questionRequestID = "demo-feed-question"
    static let planRequestID = "demo-feed-plan"
    static let multiSelectRequestID = "demo-feed-multi-select"
    static let answerOnMacRequestID = "demo-feed-answer-on-mac"
    static let expiringRequestID = "demo-feed-expiring"
    /// Seconds the `expiring` scenario's request has left when the list is first built.
    static let expiringSecondsLeft: Int64 = 20

    static func pendingItems(nowMilliseconds now: Int64, includeExpiring: Bool = false) -> [FeedPendingItem] {
        let second: Int64 = 1_000
        let expiring = FeedPendingItem(
            id: "feed-item-0",
            requestId: expiringRequestID,
            kind: .permission,
            source: "claude",
            workstreamId: "demo-workstream-4",
            createdAt: now - (Int64(FeedPendingWindow.expectedSeconds) - expiringSecondsLeft) * second,
            title: "Clear the build cache",
            cwd: "/Users/demo/dev/agent-lab",
            toolName: "Bash",
            toolInput: "{\"command\":\"rm -rf .build/cache\"}",
            availableModes: FeedLimits.permissionModes
        )
        return (includeExpiring ? [expiring] : []) + [
            FeedPendingItem(
                id: "feed-item-1",
                requestId: permissionRequestID,
                kind: .permission,
                source: "claude",
                workstreamId: "demo-workstream-1",
                createdAt: now - 10 * second,
                title: "Run the test suite",
                cwd: "/Users/demo/dev/agent-lab",
                toolName: "Bash",
                toolInput: "{\"command\":\"swift test --filter FeedStoreTests\",\"description\":\"Run the feed store tests\"}",
                availableModes: FeedLimits.permissionModes
            ),
            FeedPendingItem(
                id: "feed-item-2",
                requestId: questionRequestID,
                kind: .question,
                source: "claude",
                workstreamId: "demo-workstream-2",
                createdAt: now - 20 * second,
                title: "Pick a database",
                cwd: "/Users/demo/dev/notes-api",
                questions: [
                    FeedQuestion(id: "q1", prompt: "Which database should the notes service use?", multiSelect: false, options: [
                        FeedOption(id: "o1", label: "SQLite"),
                        FeedOption(id: "o2", label: "Postgres"),
                        FeedOption(id: "o3", label: "Keep the JSON files"),
                    ]),
                ]
            ),
            FeedPendingItem(
                id: "feed-item-3",
                requestId: planRequestID,
                kind: .plan,
                source: "claude",
                workstreamId: "demo-workstream-1",
                createdAt: now - 30 * second,
                title: "Plan: cache the session list",
                cwd: "/Users/demo/dev/agent-lab",
                availableModes: FeedLimits.planModes,
                defaultMode: "manual",
                planText: """
                ## Plan

                1. Add a `SessionCache` with a one-second lifetime.
                2. Share the in-flight request between callers.
                3. Cover expiry and sharing with unit tests.

                Files: `SessionCache.swift`, `SessionCacheTests.swift`.
                """
            ),
            FeedPendingItem(
                id: "feed-item-4",
                requestId: multiSelectRequestID,
                kind: .question,
                source: "claude",
                workstreamId: "demo-workstream-3",
                createdAt: now - 40 * second,
                title: "Choose checks",
                cwd: "/Users/demo/dev/site",
                questions: [
                    FeedQuestion(id: "q1", prompt: "Which checks should run before the release?", multiSelect: true, options: [
                        FeedOption(id: "o1", label: "Unit tests"),
                        FeedOption(id: "o2", label: "UI tests"),
                        FeedOption(id: "o3", label: "Lint"),
                    ]),
                ]
            ),
            FeedPendingItem(
                id: "feed-item-5",
                requestId: answerOnMacRequestID,
                kind: .question,
                source: "claude",
                workstreamId: "demo-workstream-3",
                createdAt: now - 50 * second,
                title: "Release details",
                cwd: "/Users/demo/dev/site",
                questions: [
                    FeedQuestion(id: "q1", prompt: "Which channel should get the build?", multiSelect: false, options: [
                        FeedOption(id: "o1", label: "Beta"),
                        FeedOption(id: "o2", label: "Stable"),
                    ]),
                    FeedQuestion(id: "q2", prompt: "Which platforms?", multiSelect: true, options: [
                        FeedOption(id: "o1", label: "iOS"),
                        FeedOption(id: "o2", label: "macOS"),
                    ]),
                ]
            ),
        ]
    }
}
