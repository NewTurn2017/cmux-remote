import Foundation
import XCTest
import SharedKit

/// Event payloads and the `notification.list` result copied from the lane fixture
/// `cmux-notification-events.json` (sha256 c8188d9cc0e8d509; key shape measured on cmux
/// build 113, values invented). Top-level envelope keys the relay does not decode are trimmed.
enum NotificationFixture {
    static let eventsJSON = #"""
    [
     {"type":"event","category":"notification","name":"notification.requested","source":"socket.v2","seq":101,
      "payload":{"method":"notification.create_for_target","params":{"title":null,"title_length":8,"subtitle":null,"subtitle_length":8,"body":null,"body_length":8,"redacted_fields":["title","subtitle","body"],"effects":{"desktop":false},"surface_id":"SF-1111","workspace_id":"WS-AAAA"},"result":{"id":"N-0001","surface_id":"SF-1111","surface_ref":"surface:1","window_id":"WIN-1","window_ref":"window:1","workspace_id":"WS-AAAA","workspace_ref":"workspace:1"}}},
     {"type":"event","category":"notification","name":"notification.created","source":"notification.store","seq":102,
      "payload":{"notification_id":"N-0001","workspace_id":"WS-AAAA","surface_id":"SF-1111","created_at":"2026-11-09T02:13:00Z","is_read":false,"delivery":"store","replaced_notification_ids":["N-0000"],"title":null,"title_length":11,"subtitle":null,"subtitle_length":7,"body":null,"body_length":32,"redacted_fields":["title","subtitle","body"]}},
     {"type":"event","category":"notification","name":"notification.read","source":"notification.store","seq":103,
      "payload":{"notification_id":"N-0001","workspace_id":"WS-AAAA","surface_id":"SF-1111","created_at":"2026-11-09T02:13:00Z","is_read":true,"title":null,"title_length":11,"subtitle":null,"subtitle_length":7,"body":null,"body_length":32,"redacted_fields":["title","subtitle","body"]}},
     {"type":"event","category":"notification","name":"notification.removed","source":"notification.store","seq":104,
      "payload":{"notification_id":"N-0001","workspace_id":"WS-AAAA","surface_id":"SF-1111","created_at":"2026-11-09T02:13:00Z","is_read":true,"title":null,"title_length":11,"subtitle":null,"subtitle_length":7,"body":null,"body_length":32,"redacted_fields":["title","subtitle","body"]}}
    ]
    """#

    static let listJSON = #"""
    {"notifications":[{"id":"N-0001","workspace_id":"WS-AAAA","workspace_ref":"workspace:1","surface_id":"SF-1111","surface_ref":"surface:1","tab_title":"claude","title":"Claude Code","subtitle":"agent-lab","body":"Claude is waiting for your input","created_at":"2026-11-09T02:13:00Z","is_read":false}]}
    """#

    static let stringsThatMustNotBeLogged = ["Claude Code", "agent-lab", "Claude is waiting", "claude", "N-0001", "WS-AAAA", "SF-1111"]

    static func events() throws -> [EventFrame] {
        try JSONDecoder().decode([EventFrame].self, from: Data(eventsJSON.utf8))
    }

    static func event(_ name: String) throws -> EventFrame {
        try XCTUnwrap(events().first { $0.name == name })
    }

    static func listResult() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(listJSON.utf8))
    }

    static func created(id: String) throws -> EventFrame {
        var event = try event("notification.created")
        guard case .object(var payload) = event.payload else { throw ShapeError() }
        payload["notification_id"] = .string(id)
        event.payload = .object(payload)
        return event
    }

    static func list(ids: [String]) -> JSONValue {
        .object(["notifications": .array(ids.map { id in
            .object(["id": .string(id), "title": .string("title \(id)"), "body": .string("body \(id)")])
        })])
    }

    struct ShapeError: Error {}
}

extension XCTestCase {
    /// Awaits `operation` for at most `timeout` seconds; a stuck wait fails the test instead of hanging it.
    func awaitBounded(
        _ description: String,
        timeout: TimeInterval = 5,
        _ operation: @escaping @Sendable () async -> Void
    ) async {
        let done = expectation(description: description)
        Task {
            await operation()
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: timeout)
    }
}

actor NotificationFrameRecorder {
    private(set) var frames: [PushFrame] = []
    private var observers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ frame: PushFrame) {
        frames.append(frame)
        let ready = observers.filter { $0.count <= frames.count }
        observers.removeAll { $0.count <= frames.count }
        for observer in ready { observer.continuation.resume() }
    }

    func waitUntil(count: Int) async {
        if frames.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    var eventNames: [String] {
        frames.compactMap { frame in
            guard case .event(let event) = frame else { return nil }
            return event.name
        }
    }
}

final class NotificationLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock(); storage.append(line); lock.unlock()
    }
}

actor NotificationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

actor NotificationDispatchScript {
    enum Answer: Sendable {
        case result(JSONValue)
        case error(RPCError)
        case transportFailure
    }

    struct TransportFailure: Error {}

    private var answers: [Answer]
    private(set) var methods: [String] = []
    private let gate: NotificationGate?
    private var enteredObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(answers: [Answer], gate: NotificationGate? = nil) {
        self.answers = answers
        self.gate = gate
    }

    func call(method: String) async throws -> JSONValue {
        methods.append(method)
        let ready = enteredObservers.filter { $0.count <= methods.count }
        enteredObservers.removeAll { $0.count <= methods.count }
        for observer in ready { observer.continuation.resume() }
        let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
        if let gate { await gate.wait() }
        switch answer {
        case .result(let value): return value
        case .error(let error): throw error
        case .transportFailure: throw TransportFailure()
        }
    }

    func waitUntilCalled(times count: Int) async {
        if methods.count >= count { return }
        await withCheckedContinuation { enteredObservers.append((count, $0)) }
    }
}
