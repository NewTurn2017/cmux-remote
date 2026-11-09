import Foundation
import Observation
import SharedKit
@testable import CmuxRemote

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

    static func permission(_ requestID: String = "perm", availableModes: [String]? = FeedLimits.permissionModes) -> FeedPendingItem {
        FeedPendingItem(
            id: "item-\(requestID)",
            requestId: requestID,
            kind: .permission,
            source: "claude",
            workstreamId: "ws-1",
            createdAt: 1_000,
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
