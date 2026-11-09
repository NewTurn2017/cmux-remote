import Foundation
import Logging
import SharedKit

/// Serves `feed.pending.list` and `feed.reply` from cmux `feed.list` and the `feed.*.reply` methods.
///
/// One instance is shared by every WebSocket connection. Overlapping list requests share one
/// cmux call and a successful list is reused for ``reuseWindow``. A reply always checks a fresh
/// pending list first, replies for one `request_id` run one after another, and a successful
/// reply drops the cached list. Log lines carry only reason words, counts, and cmux error codes,
/// never titles, prompts, labels, tool input, plan text, or paths.
actor FeedService {
    typealias Dispatch = @Sendable (String, JSONValue) async -> TerminalArtifactService.NativeResult

    enum Error: Swift.Error, Sendable, Equatable {
        case notPending
        case invalidField(String)
        case malformed
        case native(String)
    }

    enum Observation: Sendable, Equatable {
        case joinedInFlight
        case replyQueued
    }

    static let reuseWindow: TimeInterval = 1.0
    static let logger = Logger(label: "cmux-relay.feed")

    /// cmux error codes taken to mean another answer won the race between the relay's pending
    /// check and its reply. Not yet confirmed against a real already-answered request; the PM's
    /// device test records the actual code from the `feed.reply cmux error` log line.
    static let notPendingReplyCodes: Set<String> = [
        "not_found", "request_not_found", "not_pending", "already_resolved", "expired",
    ]

    private static let responseBudget = FeedLimits.maxResponseBytes - FeedLimits.responseEnvelopeReserveBytes

    private let dispatch: Dispatch
    private let clock: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private let observe: @Sendable (Observation) -> Void
    private var inFlight: Task<[FeedPendingItem], Swift.Error>?
    private var recent: (items: [FeedPendingItem], at: Date)?
    private var generation = 0
    private var replyTails: [String: Task<Void, Never>] = [:]

    init(
        dispatch: @escaping Dispatch,
        clock: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (String) -> Void = { FeedService.logger.notice("\($0)") },
        observe: @escaping @Sendable (Observation) -> Void = { _ in }
    ) {
        self.dispatch = dispatch
        self.clock = clock
        self.log = log
        self.observe = observe
    }

    init(cmux: any CMUXFacade) {
        self.init(dispatch: { method, params in
            do {
                return .success(try await cmux.dispatch(method: method, params: params))
            } catch let error as RPCError {
                return .failure(code: error.code)
            } catch {
                return .failure(code: "internal_error")
            }
        })
    }

    func pending(limit: Int) async throws -> FeedPendingListResult {
        let items = try await sharedPendingItems()
        let fitted = FeedItemTranslator.fitToBudget(Array(items.prefix(limit)), budget: Self.responseBudget)
        guard fitted.omitted > 0 else { return FeedPendingListResult(items: fitted.kept, truncated: false) }
        log("feed.pending.list truncated: kept=\(fitted.kept.count) omitted=\(fitted.omitted)")
        return FeedPendingListResult(items: fitted.kept, truncated: true, omittedCount: fitted.omitted)
    }

    func reply(_ request: FeedReplyRequest) async throws -> FeedReplyResult {
        let previous = replyTails[request.requestId]
        if previous != nil { observe(.replyQueued) }
        let operation = Task<Result<FeedReplyResult, Swift.Error>, Never> {
            await previous?.value
            do {
                return .success(try await self.performReply(request))
            } catch {
                return .failure(error)
            }
        }
        let tail = Task<Void, Never> { _ = await operation.value }
        replyTails[request.requestId] = tail
        let outcome = await operation.value
        if replyTails[request.requestId] == tail { replyTails[request.requestId] = nil }
        return try outcome.get()
    }

    // MARK: - Pending list

    private func sharedPendingItems() async throws -> [FeedPendingItem] {
        if let recent {
            let age = clock().timeIntervalSince(recent.at)
            if age >= 0 && age < Self.reuseWindow { return recent.items }
            self.recent = nil
        }
        if let running = inFlight {
            observe(.joinedInFlight)
            return try await running.value
        }
        let startedGeneration = generation
        let dispatch = self.dispatch
        let log = self.log
        let task = Task { try await Self.fetchPending(dispatch: dispatch, log: log) }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }
        let items = try await task.value
        if startedGeneration == generation { recent = (items, clock()) }
        return items
    }

    private func invalidateCache() {
        generation += 1
        recent = nil
        inFlight = nil
    }

    private static func fetchPending(
        dispatch: Dispatch,
        log: @Sendable (String) -> Void
    ) async throws -> [FeedPendingItem] {
        let rawItems: [JSONValue]
        switch await dispatch("feed.list", .object(["pending_only": .bool(true)])) {
        case .success(.object(let fields)):
            switch fields["items"] {
            case nil, .null?: rawItems = []
            case .array(let items)?: rawItems = items
            default:
                log("feed.pending.list refused: malformed_response")
                throw Error.malformed
            }
        case .success:
            log("feed.pending.list refused: malformed_response")
            throw Error.malformed
        case .failure(let code):
            log("feed.pending.list cmux error: code=\(loggableCode(code))")
            throw mapFailure(code)
        }

        var items: [FeedPendingItem] = []
        var drops: [FeedItemTranslator.Drop: Int] = [:]
        for raw in rawItems {
            switch FeedItemTranslator.translate(raw) {
            case .success(let item): items.append(item)
            case .failure(let reason): drops[reason, default: 0] += 1
            }
        }
        if !drops.isEmpty {
            let counts = FeedItemTranslator.Drop.allCases.compactMap { reason in
                drops[reason].map { "\(reason.rawValue)=\($0)" }
            }
            log("feed.pending.list dropped: \(counts.joined(separator: " "))")
        }
        return items.sorted(by: FeedItemTranslator.newestFirst)
    }

    // MARK: - Reply

    private func performReply(_ request: FeedReplyRequest) async throws -> FeedReplyResult {
        let fresh = try await Self.fetchPending(dispatch: dispatch, log: log)
        guard let item = fresh.first(where: { $0.requestId == request.requestId }) else {
            log("feed.reply refused: not_pending")
            throw Error.notPending
        }
        guard item.kind == request.kind else {
            log("feed.reply refused: kind_mismatch")
            throw Error.invalidField("kind")
        }

        let params: JSONValue
        let method: String
        switch request.kind {
        case .permission, .plan:
            let allowed = item.availableModes ?? request.kind.replyModes
            guard let mode = request.mode, allowed.contains(mode) else {
                log("feed.reply refused: invalid_mode")
                throw Error.invalidField("mode")
            }
            method = request.kind == .permission ? "feed.permission.reply" : "feed.exit_plan.reply"
            params = .object(["request_id": .string(request.requestId), "mode": .string(mode)])
        case .question:
            guard let selections = request.selections,
                  FeedItemTranslator.selectionsAnswer(item.questions ?? [], selections)
            else {
                log("feed.reply refused: invalid_selections")
                throw Error.invalidField("selections")
            }
            method = "feed.question.reply"
            params = .object([
                "request_id": .string(request.requestId),
                "selections": .array(selections.map(JSONValue.string)),
            ])
        }

        switch await dispatch(method, params) {
        case .success:
            invalidateCache()
            return FeedReplyResult(requestId: request.requestId, kind: request.kind)
        case .failure(let code):
            log("feed.reply cmux error: code=\(Self.loggableCode(code))")
            guard !Self.notPendingReplyCodes.contains(code) else {
                invalidateCache()
                throw Error.notPending
            }
            throw Self.mapFailure(code)
        }
    }

    // MARK: - Errors

    private static func mapFailure(_ code: String) -> Error {
        switch code {
        case "unauthorized", "forbidden": return .native("forbidden")
        default: return .native(code)
        }
    }

    /// The code itself when it is a short snake_case word, otherwise `other`.
    private static func loggableCode(_ code: String) -> String {
        let allowed = code.count <= 64 && !code.isEmpty && code.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
        }
        return allowed ? code : "other"
    }
}
