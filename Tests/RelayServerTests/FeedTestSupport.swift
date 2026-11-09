import Foundation
import SharedKit
@testable import RelayServer

/// Scripted cmux feed methods. `feed.list` and the reply methods can each be held on a gate
/// so tests can observe in-flight sharing and reply ordering without timing assumptions.
actor FakeFeedCMUX {
    struct Call: Equatable, Sendable {
        let method: String
        let params: JSONValue
    }

    static let replyMethods: Set<String> = ["feed.permission.reply", "feed.exit_plan.reply", "feed.question.reply"]

    private(set) var calls: [Call] = []
    private var items: [JSONValue]
    private let listFailure: String?
    private let replyFailures: [String: String]
    private let listGate: AsyncStream<Void>?
    private let listEntered: AsyncStream<Void>.Continuation?
    private let replyGate: AsyncStream<Void>?
    private let replyEntered: AsyncStream<Void>.Continuation?

    init(
        items: [JSONValue],
        listFailure: String? = nil,
        replyFailures: [String: String] = [:],
        listGate: AsyncStream<Void>? = nil,
        listEntered: AsyncStream<Void>.Continuation? = nil,
        replyGate: AsyncStream<Void>? = nil,
        replyEntered: AsyncStream<Void>.Continuation? = nil
    ) {
        self.items = items
        self.listFailure = listFailure
        self.replyFailures = replyFailures
        self.listGate = listGate
        self.listEntered = listEntered
        self.replyGate = replyGate
        self.replyEntered = replyEntered
    }

    nonisolated var dispatch: FeedService.Dispatch {
        { [self] method, params in await self.handle(method, params) }
    }

    func count(of method: String) -> Int { calls.filter { $0.method == method }.count }

    func replyCount() -> Int { calls.filter { Self.replyMethods.contains($0.method) }.count }

    func params(of method: String) -> [JSONValue] { calls.filter { $0.method == method }.map(\.params) }

    private func handle(_ method: String, _ params: JSONValue) async -> TerminalArtifactService.NativeResult {
        calls.append(Call(method: method, params: params))
        if method == "feed.list" {
            listEntered?.yield()
            if let listGate {
                for await _ in listGate { break }
            }
            if let listFailure { return .failure(code: listFailure) }
            return .success(.object(["items": .array(items)]))
        }
        guard Self.replyMethods.contains(method) else { return .failure(code: "method_not_found") }
        replyEntered?.yield()
        if let replyGate {
            for await _ in replyGate { break }
        }
        if let code = replyFailures[method] { return .failure(code: code) }
        if case .object(let fields) = params, case .string(let requestId)? = fields["request_id"] {
            items.removeAll { FeedRaw.requestId(of: $0) == requestId }
        }
        return .success(.object([:]))
    }
}

/// Builders for raw cmux `feed.list` items.
enum FeedRaw {
    static func item(
        id: String,
        kind: String,
        status: String = "pending",
        requestId: String? = nil,
        createdAt: String? = "2026-11-09T10:00:00Z",
        source: String = "claude",
        _ extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id), "workstream_id": .string("ws-1"), "source": .string(source),
            "kind": .string(kind), "status": .string(status), "cwd": .string("/tmp/project"),
        ]
        if let requestId { fields["request_id"] = .string(requestId) }
        if let createdAt { fields["created_at"] = .string(createdAt) }
        fields.merge(extra) { _, new in new }
        return .object(fields)
    }

    static func option(_ id: String, _ label: String) -> JSONValue {
        .object(["id": .string(id), "label": .string(label)])
    }

    static func question(_ id: String?, prompt: String?, multiSelect: Bool = false, options: [JSONValue]) -> JSONValue {
        var fields: [String: JSONValue] = ["options": .array(options), "multi_select": .bool(multiSelect)]
        if let id { fields["id"] = .string(id) }
        if let prompt { fields["prompt"] = .string(prompt) }
        return .object(fields)
    }

    static func singleQuestion(id: String, requestId: String, labels: [String], multiSelect: Bool = false) -> JSONValue {
        item(id: id, kind: "question", requestId: requestId, [
            "questions": .array([question("q1", prompt: "Pick", multiSelect: multiSelect,
                                          options: labels.enumerated().map { option("o\($0.offset)", $0.element) })]),
        ])
    }

    static func requestId(of item: JSONValue) -> String? {
        guard case .object(let fields) = item, case .string(let value)? = fields["request_id"] else { return nil }
        return value
    }
}
