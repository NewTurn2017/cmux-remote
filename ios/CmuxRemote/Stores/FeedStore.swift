import Foundation
import Observation
import SharedKit

enum FeedRefreshPolicy {
    static let listIntervalSeconds: Double = 3
    static let badgeIntervalSeconds: Double = 15
    /// A list fetched just after a reply can still contain the answered request; hide it this long.
    static let answeredHideSeconds: Double = 30
}

enum FeedListFailure: Equatable, Sendable {
    case disconnected
    case temporarilyUnavailable
    case generic

    init(error: Error) {
        switch error {
        case let CmuxRemoteRPCError.rpc(code, _):
            switch code {
            case "offline": self = .disconnected
            case "temporarily_unavailable": self = .temporarilyUnavailable
            default: self = .generic
            }
        case RPCClientError.closed:
            self = .disconnected
        case RPCClientError.timeout:
            self = .temporarilyUnavailable
        default:
            self = .generic
        }
    }

    var message: String {
        switch self {
        case .disconnected:
            return String(localized: "feed.error.disconnected", defaultValue: "Relay disconnected. Pending requests will load when it reconnects.")
        case .temporarilyUnavailable:
            return String(localized: "feed.error.temporarily_unavailable", defaultValue: "The Mac didn't answer in time. Retrying shortly.")
        case .generic:
            return String(localized: "feed.error.generic", defaultValue: "Couldn't load pending requests. Retrying shortly.")
        }
    }
}

enum FeedListState: Equatable {
    case idle
    case loading
    case loaded
    case failed(FeedListFailure)
    /// The relay advertised `feed.v1` but does not answer `feed.pending.list`.
    case unsupported
}

enum FeedNotice: Equatable {
    case alreadyHandled
    case verifying
}

enum FeedReplyFailure: Equatable {
    /// The reply's outcome was unknown and the request is still pending afterwards.
    case notConfirmed
    case rejected
    case disconnected

    var message: String {
        switch self {
        case .notConfirmed:
            return String(localized: "feed.reply.error.not_confirmed", defaultValue: "The answer may not have arrived. Try again.")
        case .rejected:
            return String(localized: "feed.reply.error.rejected", defaultValue: "The Mac didn't accept this answer.")
        case .disconnected:
            return String(localized: "feed.reply.error.disconnected", defaultValue: "Not connected to the relay.")
        }
    }
}

/// Owns the pending feed requests, their refresh loop, and replies.
///
/// At most one list request is in flight. A reply is sent at most once per request id: while
/// it is in flight or being verified, further replies for that id are dropped. When a reply's
/// outcome is unknown (timeout, closed connection, `temporarily_unavailable`) it is never
/// resent; a list fetched after the reply decides whether it arrived.
@MainActor
@Observable
final class FeedStore {
    private(set) var items: [FeedPendingItem] = []
    private(set) var omittedCount = 0
    private(set) var state: FeedListState = .idle
    private(set) var sendingRequestIDs: Set<String> = []
    private(set) var replyFailures: [String: FeedReplyFailure] = [:]
    private(set) var notice: FeedNotice?
    private(set) var noticeID = 0

    @ObservationIgnored private let rpc: any RPCDispatch
    @ObservationIgnored private let sleeper: any BrowserRefreshSleeper
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var loopToken: UInt64 = 0
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var listSequence = 0
    @ObservationIgnored private var answeredAt: [String: Date] = [:]
    /// Request id -> first list sequence allowed to decide whether the reply arrived.
    private(set) var verifying: [String: Int] = [:]

    init(
        rpc: any RPCDispatch,
        sleeper: any BrowserRefreshSleeper = SystemBrowserRefreshSleeper(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rpc = rpc
        self.sleeper = sleeper
        self.now = now
    }

    var pendingCount: Int { items.count + omittedCount }
    var isUnsupported: Bool { state == .unsupported }

    func isBusy(_ requestID: String) -> Bool {
        sendingRequestIDs.contains(requestID) || verifying[requestID] != nil
    }

    /// Lists repeatedly while the calling task lives. Views run this from `.task(id:)`, so
    /// hiding the tab bar, backgrounding the app, or disconnecting cancels it.
    func runRefreshLoop(intervalSeconds: Double, isConnected: Bool, isActive: Bool) async {
        guard isConnected else {
            markDisconnected()
            return
        }
        guard isActive, state != .unsupported else { return }
        loopToken &+= 1
        let token = loopToken
        while !Task.isCancelled, loopToken == token {
            await refresh()
            guard !Task.isCancelled, loopToken == token, state != .unsupported else { return }
            let delay = BrowserRefreshPolicy.delaySeconds(
                consecutiveFailures: consecutiveFailures,
                baseSeconds: intervalSeconds
            )
            do {
                try await sleeper.sleep(seconds: delay)
            } catch {
                return
            }
        }
    }

    /// Lists once. With `fresh`, a list already in flight is awaited and a new one started,
    /// so the result reflects everything that happened before this call.
    func refresh(fresh: Bool = false) async {
        guard state != .unsupported else { return }
        if let inFlight {
            await inFlight.value
            guard fresh else { return }
            if let next = self.inFlight {
                await next.value
                return
            }
        }
        guard state != .unsupported else { return }
        listSequence += 1
        let sequence = listSequence
        let expected = generation
        let task = Task { await self.performList(generation: expected, sequence: sequence) }
        inFlight = task
        await task.value
    }

    func reply(_ request: FeedReplyRequest) async {
        let requestID = request.requestId
        guard state != .unsupported, !isBusy(requestID) else { return }
        sendingRequestIDs.insert(requestID)
        replyFailures[requestID] = nil
        let expected = generation
        let outcome: Result<Void, Error>
        do {
            let response = try await rpc.call(
                method: RemoteRPCMethod.feedReply.rawValue,
                params: try Self.params(request)
            )
            _ = try response.unwrapResult().decode(FeedReplyResult.self)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        guard expected == generation else { return }
        sendingRequestIDs.remove(requestID)
        switch outcome {
        case .success:
            markAnswered(requestID)
            await refresh(fresh: true)
        case .failure(CmuxRemoteRPCError.rpc(let code, _)) where code == RemoteErrorCode.feedRequestNotPending.rawValue:
            markAnswered(requestID)
            show(.alreadyHandled)
            await refresh(fresh: true)
        case .failure(CmuxRemoteRPCError.rpc(let code, _)) where code == RemoteErrorCode.methodNotFound.rawValue:
            markUnsupported()
        case .failure(CmuxRemoteRPCError.rpc(let code, _)) where code == "offline":
            replyFailures[requestID] = .disconnected
        case .failure(let error) where Self.outcomeIsUnknown(error):
            verifying[requestID] = listSequence + 1
            show(.verifying)
            await refresh(fresh: true)
        case .failure:
            replyFailures[requestID] = .rejected
        }
    }

    func dismissNotice(id: Int) {
        guard id == noticeID else { return }
        notice = nil
    }

    func reset() {
        generation &+= 1
        loopToken &+= 1
        inFlight = nil
        items = []
        omittedCount = 0
        state = .idle
        sendingRequestIDs = []
        replyFailures = [:]
        verifying = [:]
        answeredAt = [:]
        notice = nil
        consecutiveFailures = 0
    }

    private static func outcomeIsUnknown(_ error: Error) -> Bool {
        switch error {
        case RPCClientError.timeout, RPCClientError.closed, is CancellationError:
            return true
        case let CmuxRemoteRPCError.rpc(code, _):
            return code == "temporarily_unavailable"
        case is DecodingError, is RemoteProtocolError, CmuxRemoteRPCError.missingResult:
            return true
        default:
            return false
        }
    }

    private static func params(_ request: FeedReplyRequest) throws -> JSONValue {
        let data = try SharedKitJSON.snakeCaseEncoder.encode(request)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func performList(generation expected: UInt64, sequence: Int) async {
        if state == .idle { state = .loading }
        let outcome: Result<FeedPendingListResult, Error>
        do {
            let response = try await rpc.call(
                method: RemoteRPCMethod.feedPendingList.rawValue,
                params: .object([:])
            )
            outcome = .success(try response.unwrapResult().decode(FeedPendingListResult.self))
        } catch {
            outcome = .failure(error)
        }
        guard expected == generation else { return }
        inFlight = nil
        switch outcome {
        case .success(let result):
            apply(result, sequence: sequence)
        case .failure(CmuxRemoteRPCError.rpc(let code, _)) where code == RemoteErrorCode.methodNotFound.rawValue:
            markUnsupported()
        case .failure(let error):
            consecutiveFailures += 1
            state = .failed(FeedListFailure(error: error))
        }
    }

    private func apply(_ result: FeedPendingListResult, sequence: Int) {
        consecutiveFailures = 0
        let current = now()
        answeredAt = answeredAt.filter { current.timeIntervalSince($0.value) < FeedRefreshPolicy.answeredHideSeconds }
        let pendingIDs = Set(result.items.map(\.requestId))
        for (requestID, firstSequence) in verifying where sequence >= firstSequence {
            verifying[requestID] = nil
            if pendingIDs.contains(requestID) {
                replyFailures[requestID] = .notConfirmed
            } else {
                answeredAt[requestID] = current
            }
        }
        if verifying.isEmpty, notice == .verifying { notice = nil }
        items = result.items.filter { answeredAt[$0.requestId] == nil }
        omittedCount = result.truncated ? (result.omittedCount ?? 0) : 0
        let visibleIDs = Set(items.map(\.requestId))
        replyFailures = replyFailures.filter { visibleIDs.contains($0.key) }
        state = .loaded
    }

    private func markAnswered(_ requestID: String) {
        answeredAt[requestID] = now()
        items.removeAll { $0.requestId == requestID }
        replyFailures[requestID] = nil
    }

    private func markDisconnected() {
        state = .failed(.disconnected)
    }

    private func markUnsupported() {
        state = .unsupported
        items = []
        omittedCount = 0
        sendingRequestIDs = []
        verifying = [:]
        notice = nil
    }

    private func show(_ next: FeedNotice) {
        noticeID += 1
        notice = next
    }
}
