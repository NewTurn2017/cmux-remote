import Foundation
import Observation
import SharedKit

enum ClaudeTranscriptRefreshPolicy {
    /// Latest-page check for a live session while its transcript is visible near the bottom.
    static let liveCheckSeconds: Double = 10
    /// Older pages requested in a row when they hold nothing to show before waiting for the user.
    static let maxEmptyOlderPages = 3
}

enum ClaudeTranscriptFailure: Equatable, Sendable {
    case disconnected
    case sessionNotFound
    case temporarilyUnavailable
    case generic

    init(error: Error) {
        switch error {
        case let CmuxRemoteRPCError.rpc(code, _):
            switch code {
            case "offline": self = .disconnected
            case "temporarily_unavailable": self = .temporarilyUnavailable
            case RemoteErrorCode.claudeSessionNotFound.rawValue: self = .sessionNotFound
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

    var canRetry: Bool { self != .sessionNotFound }

    var message: String {
        switch self {
        case .disconnected:
            return String(localized: "transcript.error.disconnected", defaultValue: "Relay disconnected.")
        case .sessionNotFound:
            return String(localized: "transcript.error.session_not_found", defaultValue: "Session not found. It may have been removed on the Mac.")
        case .temporarilyUnavailable:
            return String(localized: "transcript.error.temporarily_unavailable", defaultValue: "The Mac didn't answer in time.")
        case .generic:
            return String(localized: "transcript.error.generic", defaultValue: "Couldn't load the conversation.")
        }
    }
}

enum ClaudeSessionListState: Equatable {
    case idle
    case loading
    case loaded
    case failed(ClaudeTranscriptFailure)
    /// The relay advertised `claude.transcript.v1` but does not answer `claude.sessions.list`.
    case unsupported
}

enum ClaudeTranscriptState: Equatable {
    case idle
    case loading
    case loaded
    case failed(ClaudeTranscriptFailure)
}

/// Owns the Claude session list and the one transcript that is open.
///
/// One page request runs at a time. Responses that arrive after the session was closed,
/// another one was opened, or the host changed are dropped.
@MainActor
@Observable
final class ClaudeTranscriptStore {
    private(set) var sessions: [ClaudeSessionSummary] = []
    private(set) var sessionsState: ClaudeSessionListState = .idle
    private(set) var openSession: ClaudeSessionSummary?
    private(set) var timeline = ClaudeTranscriptTimeline()
    private(set) var transcriptState: ClaudeTranscriptState = .idle
    private(set) var isLoadingOlder = false
    private(set) var isRefreshingLatest = false
    private(set) var olderFailure: ClaudeTranscriptFailure?
    private(set) var latestFailure: ClaudeTranscriptFailure?
    private(set) var expandedBlocks: Set<String> = []
    /// Row to keep in place after an older page was added above it.
    private(set) var prependAnchorID: String?
    private(set) var prependSequence = 0
    /// Bumped when the newest page replaced or extended the rows.
    private(set) var latestSequence = 0

    @ObservationIgnored private let rpc: any RPCDispatch
    @ObservationIgnored private let sleeper: any BrowserRefreshSleeper
    @ObservationIgnored private let maxEmptyOlderPages: Int
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var sessionsInFlight = false
    @ObservationIgnored private var pageInFlight = false

    init(
        rpc: any RPCDispatch,
        sleeper: any BrowserRefreshSleeper = SystemBrowserRefreshSleeper(),
        maxEmptyOlderPages: Int = ClaudeTranscriptRefreshPolicy.maxEmptyOlderPages
    ) {
        self.rpc = rpc
        self.sleeper = sleeper
        self.maxEmptyOlderPages = maxEmptyOlderPages
    }

    var isUnsupported: Bool { sessionsState == .unsupported }
    var isOpenSessionLive: Bool { openSession?.status == "live" }

    static func blockKey(rowID: String, index: Int) -> String { "\(rowID)#\(index)" }

    func isExpanded(rowID: String, index: Int) -> Bool {
        expandedBlocks.contains(Self.blockKey(rowID: rowID, index: index))
    }

    func toggleExpanded(rowID: String, index: Int) {
        let key = Self.blockKey(rowID: rowID, index: index)
        if expandedBlocks.contains(key) {
            expandedBlocks.remove(key)
        } else {
            expandedBlocks.insert(key)
        }
    }

    // MARK: sessions

    func loadSessions() async {
        guard sessionsState != .unsupported, !sessionsInFlight else { return }
        sessionsInFlight = true
        if sessions.isEmpty { sessionsState = .loading }
        let expected = generation
        let outcome: Result<ClaudeSessionListResult, Error>
        do {
            let response = try await rpc.call(
                method: RemoteRPCMethod.claudeSessionsList.rawValue,
                params: .object([:])
            )
            outcome = .success(try response.unwrapResult().decode(ClaudeSessionListResult.self))
        } catch {
            outcome = .failure(error)
        }
        guard expected == generation else { return }
        sessionsInFlight = false
        switch outcome {
        case .success(let result):
            sessions = result.sessions.enumerated().sorted { lhs, rhs in
                let left = lhs.element.modifiedAt ?? .min
                let right = rhs.element.modifiedAt ?? .min
                return left == right ? lhs.offset < rhs.offset : left > right
            }.map(\.element)
            sessionsState = .loaded
        case .failure(CmuxRemoteRPCError.rpc(let code, _)) where code == RemoteErrorCode.methodNotFound.rawValue:
            markUnsupported()
        case .failure(let error):
            sessionsState = .failed(ClaudeTranscriptFailure(error: error))
        }
    }

    // MARK: transcript

    func open(_ session: ClaudeSessionSummary) async {
        generation &+= 1
        clearTranscript()
        openSession = session
        transcriptState = .loading
        await loadLatest(replacing: true)
    }

    func close() {
        generation &+= 1
        clearTranscript()
        sessionsInFlight = false
    }

    /// Loads the newest page again from scratch, after an error or to leave a trimmed timeline.
    func reloadLatest() async {
        guard openSession != nil, !pageInFlight else { return }
        if timeline.rows.isEmpty { transcriptState = .loading }
        await loadLatest(replacing: true)
    }

    /// Checks the newest page and adds what is new; used by the refresh button and live checks.
    func refreshLatest() async {
        guard openSession != nil, !pageInFlight, transcriptState == .loaded else { return }
        await loadLatest(replacing: timeline.newerTrimmed)
    }

    /// Loads the next older page. `attachWhen` runs after a page arrives and before it is added
    /// above the rows, so the view can wait until scrolling has settled.
    func loadOlder(attachWhen ready: (@MainActor () async -> Void)? = nil) async {
        guard let session = openSession, var cursor = timeline.olderBefore,
              !pageInFlight, transcriptState == .loaded
        else { return }
        let expected = generation
        pageInFlight = true
        isLoadingOlder = true
        olderFailure = nil
        var requests = 0
        var restartFromLatest = false
        while true {
            requests += 1
            let outcome = await fetchPage(sessionID: session.sessionId, before: cursor)
            guard expected == generation else { return }
            switch outcome {
            case .success(let page):
                if let ready, !page.rows.isEmpty {
                    await ready()
                    guard expected == generation else { return }
                }
                let anchor = timeline.prependOlder(page.rows, before: page.before)
                if page.rows.isEmpty, let next = page.before, requests < maxEmptyOlderPages {
                    cursor = next
                    continue
                }
                if !page.rows.isEmpty, let anchor {
                    prependAnchorID = anchor
                    prependSequence += 1
                }
            case .failure(.invalidBefore):
                restartFromLatest = true
            case .failure(.failed(.sessionNotFound)):
                transcriptState = .failed(.sessionNotFound)
            case .failure(.failed(let failure)):
                olderFailure = failure
            }
            break
        }
        pageInFlight = false
        isLoadingOlder = false
        if restartFromLatest {
            await loadLatest(replacing: true)
        }
    }

    /// Checks the newest page every ``ClaudeTranscriptRefreshPolicy/liveCheckSeconds`` while the
    /// calling task lives. Views run this from `.task(id:)` keyed on visibility, scene phase,
    /// connection, and whether the bottom is on screen, so any change restarts or stops it.
    func runLiveLoop(isConnected: Bool, isActive: Bool, isNearBottom: Bool) async {
        guard isConnected, isActive, isNearBottom, isOpenSessionLive,
              let sessionID = openSession?.sessionId
        else { return }
        while !Task.isCancelled {
            do {
                try await sleeper.sleep(seconds: ClaudeTranscriptRefreshPolicy.liveCheckSeconds)
            } catch {
                return
            }
            guard !Task.isCancelled, openSession?.sessionId == sessionID else { return }
            await refreshLatest()
        }
    }

    func reset() {
        generation &+= 1
        clearTranscript()
        sessions = []
        sessionsState = .idle
        sessionsInFlight = false
    }

    // MARK: private

    private struct LoadedPage {
        let rows: [ClaudeTranscriptRow]
        let before: Int64?
    }

    private enum PageError: Error {
        case invalidBefore
        case failed(ClaudeTranscriptFailure)
    }

    private func loadLatest(replacing: Bool) async {
        guard let session = openSession else { return }
        let expected = generation
        pageInFlight = true
        isRefreshingLatest = true
        latestFailure = nil
        let outcome = await fetchPage(sessionID: session.sessionId, before: nil)
        guard expected == generation else { return }
        pageInFlight = false
        isRefreshingLatest = false
        switch outcome {
        case .success(let page):
            if replacing || timeline.rows.isEmpty {
                timeline.replaceWithLatest(page.rows, before: page.before)
                latestSequence += 1
            } else if timeline.applyLatest(page.rows, before: page.before) != .unchanged {
                latestSequence += 1
            }
            transcriptState = .loaded
            olderFailure = nil
            if timeline.rows.isEmpty, timeline.olderBefore != nil {
                await loadOlder()
            }
        case .failure(.failed(.sessionNotFound)):
            transcriptState = .failed(.sessionNotFound)
        case .failure(.failed(let failure)) where !timeline.rows.isEmpty:
            latestFailure = failure
        case .failure(.failed(let failure)):
            transcriptState = .failed(failure)
        case .failure(.invalidBefore):
            if timeline.rows.isEmpty {
                transcriptState = .failed(.generic)
            } else {
                latestFailure = .generic
            }
        }
    }

    private func fetchPage(sessionID: String, before: Int64?) async -> Result<LoadedPage, PageError> {
        do {
            let response = try await rpc.call(
                method: RemoteRPCMethod.claudeTranscriptPage.rawValue,
                params: try Self.params(ClaudeTranscriptPageRequest(sessionId: sessionID, before: before))
            )
            if let error = response.error, error.code == RemoteErrorCode.invalidField.rawValue,
               Self.field(of: error) == "before"
            {
                return .failure(.invalidBefore)
            }
            let page = try response.unwrapResult().decode(ClaudeTranscriptPageResult.self)
            let entries = page.entries
            let rows = await Task.detached(priority: .userInitiated) {
                entries.map(ClaudeTranscriptRow.init(entry:))
            }.value
            return .success(LoadedPage(rows: rows, before: page.before))
        } catch {
            return .failure(.failed(ClaudeTranscriptFailure(error: error)))
        }
    }

    private static func field(of error: RPCError) -> String? {
        guard case .object(let data)? = error.data, case .string(let field)? = data["field"] else { return nil }
        return field
    }

    private static func params<Value: Encodable>(_ request: Value) throws -> JSONValue {
        let data = try SharedKitJSON.snakeCaseEncoder.encode(request)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func clearTranscript() {
        openSession = nil
        timeline = ClaudeTranscriptTimeline()
        transcriptState = .idle
        isLoadingOlder = false
        isRefreshingLatest = false
        olderFailure = nil
        latestFailure = nil
        expandedBlocks = []
        prependAnchorID = nil
        pageInFlight = false
    }

    private func markUnsupported() {
        sessionsState = .unsupported
        sessions = []
        clearTranscript()
    }
}
