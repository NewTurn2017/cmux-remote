import Foundation
import SharedKit

/// Fills in the notification content cmux redacts from `events.stream`.
///
/// cmux sends `notification.created` with `title`, `subtitle` and `body` set to null, plus
/// `*_length` and `redacted_fields`. The content is available from `notification.list`, so
/// the relay looks the notification up by `notification_id` before the event reaches phones
/// and APNs. One list result serves every event it contains for a short while, and an event
/// that arrives while a list call is running waits for that call. Because that call may have
/// been answered before the notification existed, a miss there earns exactly one fresh call.
/// When the lookup fails, runs out of time or finds nothing, the event is forwarded unchanged.
///
/// Log lines carry outcome names, cmux error codes and counts only, never notification text,
/// tab titles, ids or paths.
actor NotificationContentEnricher {
    typealias Dispatch = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue

    enum Outcome: String, Sendable {
        case filled
        case notFound = "not_found"
        case failed
        case timedOut = "timed_out"
    }

    struct Counts: Sendable, Equatable {
        var filled = 0
        var notFound = 0
        var failed = 0
        var timedOut = 0
        var listCalls = 0
    }

    struct Content: Sendable, Equatable {
        var title: String?
        var subtitle: String?
        var body: String?
        var tabTitle: String?
    }

    static let listMethod = "notification.list"
    static let titleLimit = 512
    static let subtitleLimit = 512
    static let bodyLimit = 4_096
    static let tabTitleLimit = 256

    private enum Fetch: Sendable {
        case list([String: Content])
        case failed(code: String)
    }

    private let dispatch: Dispatch
    private let timeout: Duration
    private let cacheLifetime: Duration
    private let log: @Sendable (String) -> Void
    private let clock = ContinuousClock()

    private var startedFetches = 0
    private var inFlight: (serial: Int, task: Task<Fetch, Never>)?
    private var cache: (fetchedAt: ContinuousClock.Instant, entries: [String: Content])?
    private(set) var counts = Counts()
    private var waitingFills = 0
    private var waitingObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// - Parameters:
    ///   - dispatch: cmux RPC on the ordinary dispatch connection.
    ///   - timeout: Longest an event waits for its content before it is forwarded unfilled.
    ///   - cacheLifetime: How long one `notification.list` result answers later events.
    ///   - log: Receives one count-only line per enrichment attempt.
    init(
        dispatch: @escaping Dispatch,
        timeout: Duration = .milliseconds(1_500),
        cacheLifetime: Duration = .seconds(2),
        log: @escaping @Sendable (String) -> Void
    ) {
        self.dispatch = dispatch
        self.timeout = timeout
        self.cacheLifetime = cacheLifetime
        self.log = log
    }

    func fill(_ event: EventFrame) async -> EventFrame {
        guard event.name == InboxNotification.createdEventName,
              case .object(let payload) = event.payload,
              case .string(let id)? = payload["notification_id"], !id.isEmpty
        else { return event }

        let floor = startedFetches
        if let content = cachedContent(for: id) {
            return finish(.filled, event: event, filling: payload, with: content)
        }

        let deadline = clock.now + timeout
        var attempt = inFlight ?? startFetch()
        while true {
            let remaining = deadline - clock.now
            guard remaining > .zero else { return finish(.timedOut, event: event) }
            let task = attempt.task
            adjustWaiting(by: 1)
            let outcome = await BoundedRelayWork.run(timeout: remaining, { await task.value })
            adjustWaiting(by: -1)
            switch outcome {
            case .timedOut:
                return finish(.timedOut, event: event)
            case .finished(.failed(let code)):
                return finish(.failed, event: event, code: code)
            case .finished(.list(let entries)):
                if let content = entries[id] {
                    return finish(.filled, event: event, filling: payload, with: content)
                }
                guard attempt.serial <= floor else { return finish(.notFound, event: event) }
                attempt = fetch(startedAfter: floor)
            }
        }
    }

    /// Test seam: returns once `count` events are waiting on a list call.
    func waitUntilWaiting(count: Int) async {
        if waitingFills >= count { return }
        await withCheckedContinuation { waitingObservers.append((count, $0)) }
    }

    private func adjustWaiting(by delta: Int) {
        waitingFills += delta
        let ready = waitingObservers.filter { $0.count <= waitingFills }
        waitingObservers.removeAll { $0.count <= waitingFills }
        for observer in ready { observer.continuation.resume() }
    }

    private func cachedContent(for id: String) -> Content? {
        guard let cache, clock.now - cache.fetchedAt < cacheLifetime else { return nil }
        return cache.entries[id]
    }

    private func fetch(startedAfter floor: Int) -> (serial: Int, task: Task<Fetch, Never>) {
        if let inFlight, inFlight.serial > floor { return inFlight }
        return startFetch()
    }

    private func startFetch() -> (serial: Int, task: Task<Fetch, Never>) {
        startedFetches += 1
        counts.listCalls += 1
        let serial = startedFetches
        let dispatch = self.dispatch
        let task = Task<Fetch, Never> {
            let fetched = await Self.load(dispatch: dispatch)
            self.completeFetch(serial: serial, fetched)
            return fetched
        }
        inFlight = (serial, task)
        return (serial, task)
    }

    private func completeFetch(serial: Int, _ fetched: Fetch) {
        if inFlight?.serial == serial { inFlight = nil }
        if case .list(let entries) = fetched {
            cache = (clock.now, entries)
        }
    }

    private static func load(dispatch: Dispatch) async -> Fetch {
        let result: JSONValue
        do {
            result = try await dispatch(listMethod, .object([:]))
        } catch let error as RPCError {
            return .failed(code: error.code)
        } catch {
            return .failed(code: "unavailable")
        }
        guard case .object(let object) = result,
              case .array(let notifications)? = object["notifications"]
        else { return .failed(code: "invalid_response") }

        var entries: [String: Content] = [:]
        for case .object(let item) in notifications {
            guard let id = item.nonEmptyString("id") else { continue }
            entries[id] = Content(
                title: item.nonEmptyString("title"),
                subtitle: item.nonEmptyString("subtitle"),
                body: item.nonEmptyString("body"),
                tabTitle: item.nonEmptyString("tab_title")
            )
        }
        return .list(entries)
    }

    private func finish(
        _ outcome: Outcome,
        event: EventFrame,
        filling payload: [String: JSONValue]? = nil,
        with content: Content? = nil,
        code: String? = nil
    ) -> EventFrame {
        switch outcome {
        case .filled: counts.filled += 1
        case .notFound: counts.notFound += 1
        case .failed: counts.failed += 1
        case .timedOut: counts.timedOut += 1
        }
        let codePart = code.map { " code=\($0)" } ?? ""
        log("notification content \(outcome.rawValue)\(codePart) filled=\(counts.filled) "
            + "not_found=\(counts.notFound) failed=\(counts.failed) timed_out=\(counts.timedOut) "
            + "list_calls=\(counts.listCalls)")

        guard let payload, let content else { return event }
        var filledEvent = event
        filledEvent.payload = .object(Self.filled(payload, with: content))
        return filledEvent
    }

    static func filled(_ payload: [String: JSONValue], with content: Content) -> [String: JSONValue] {
        var result = payload
        var filledKeys: Set<String> = []
        for (key, value, limit) in [
            ("title", content.title, titleLimit),
            ("subtitle", content.subtitle, subtitleLimit),
            ("body", content.body, bodyLimit),
        ] {
            guard let value else { continue }
            result[key] = .string(capped(value, limit: limit))
            filledKeys.insert(key)
        }
        if let tabTitle = content.tabTitle {
            result["tab_title"] = .string(capped(tabTitle, limit: tabTitleLimit))
        }
        if case .array(let redacted)? = result["redacted_fields"] {
            let remaining = redacted.filter { field in
                guard case .string(let key) = field else { return true }
                return !filledKeys.contains(key)
            }
            result["redacted_fields"] = remaining.isEmpty ? nil : .array(remaining)
        }
        return result
    }

    static func capped(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func nonEmptyString(_ key: String) -> String? {
        guard case .string(let value)? = self[key], !value.isEmpty else { return nil }
        return value
    }
}
