import Foundation
import Observation
import SharedKit
@testable import CmuxRemote

final class FeedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = BrowserFixtures.fixedNow) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(seconds: Double) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// Suspends until `condition` holds, waking only when an observed property it reads changes.
@MainActor
func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                continuation.resume()
            }
        }
    }
}

enum FeedFixtures {
    static let list = RemoteRPCMethod.feedPendingList.rawValue
    static let reply = RemoteRPCMethod.feedReply.rawValue

    /// Ten seconds before ``BrowserFixtures/fixedNow``, well inside the pending window.
    static let recentCreatedAt: Int64 = Int64(BrowserFixtures.fixedNow.timeIntervalSince1970 * 1_000) - 10_000

    static func createdAt(secondsBefore now: Date, _ seconds: Double) -> Int64 {
        Int64((now.timeIntervalSince1970 - seconds) * 1_000)
    }

    static func permission(
        _ requestID: String = "perm",
        availableModes: [String]? = FeedLimits.permissionModes,
        createdAt: Int64? = recentCreatedAt
    ) -> FeedPendingItem {
        FeedPendingItem(
            id: "item-\(requestID)",
            requestId: requestID,
            kind: .permission,
            source: "claude",
            workstreamId: "ws-1",
            createdAt: createdAt,
            title: "Run tests",
            cwd: "/tmp/project",
            toolName: "Bash",
            toolInput: "{\"command\":\"make test\"}",
            availableModes: availableModes
        )
    }

    static func plan(_ requestID: String = "plan", defaultMode: String? = "manual", availableModes: [String]? = FeedLimits.planModes) -> FeedPendingItem {
        FeedPendingItem(
            id: "item-\(requestID)",
            requestId: requestID,
            kind: .plan,
            source: "claude",
            workstreamId: "ws-1",
            availableModes: availableModes,
            defaultMode: defaultMode,
            planText: "## Plan\n\n1. Step"
        )
    }

    static func question(_ requestID: String = "question", questions: [FeedQuestion] = [singleSelect()]) -> FeedPendingItem {
        FeedPendingItem(
            id: "item-\(requestID)",
            requestId: requestID,
            kind: .question,
            source: "claude",
            workstreamId: "ws-1",
            questions: questions
        )
    }

    static func singleSelect(_ id: String = "q1", labels: [String] = ["A", "B", "C"]) -> FeedQuestion {
        FeedQuestion(id: id, prompt: "Pick one", multiSelect: false, options: options(labels))
    }

    static func multiSelect(_ id: String = "q1", labels: [String] = ["A", "B", "C"]) -> FeedQuestion {
        FeedQuestion(id: id, prompt: "Pick some", multiSelect: true, options: options(labels))
    }

    static func options(_ labels: [String]) -> [FeedOption] {
        labels.enumerated().map { FeedOption(id: "o\($0.offset)", label: $0.element) }
    }

    static func listResponse(_ items: [FeedPendingItem], truncated: Bool = false, omittedCount: Int? = nil) throws -> RPCResponse {
        try encoded(FeedPendingListResult(items: items, truncated: truncated, omittedCount: omittedCount))
    }

    static func replyResponse(_ requestID: String, kind: FeedItemKind) throws -> RPCResponse {
        try encoded(FeedReplyResult(requestId: requestID, kind: kind))
    }

    static func error(_ code: String) -> RPCResponse {
        DocumentFixtures.error(code)
    }

    private static func encoded<Value: Encodable>(_ value: Value) throws -> RPCResponse {
        let data = try SharedKitJSON.snakeCaseEncoder.encode(value)
        return RPCResponse(id: "feed", ok: true, result: try JSONDecoder().decode(JSONValue.self, from: data))
    }
}
