import Foundation
import SharedKit
import Testing
@testable import CmuxRemote

@MainActor
private final class AttachSignal {
    private var isReached = false
    private var reachedWaiter: CheckedContinuation<Void, Never>?
    private var opened: CheckedContinuation<Void, Never>?

    func wait() async {
        isReached = true
        reachedWaiter?.resume()
        reachedWaiter = nil
        await withCheckedContinuation { opened = $0 }
    }

    func waitUntilReached() async {
        guard !isReached else { return }
        await withCheckedContinuation { reachedWaiter = $0 }
    }

    func open() {
        opened?.resume()
        opened = nil
    }
}

@Suite("ClaudeTranscriptStoreTests", .serialized, .timeLimit(.minutes(1)))
struct ClaudeTranscriptStoreTests {
    private typealias F = TranscriptFixtures

    @MainActor
    private func makeStore(_ rpc: DocumentRPCStub, sleeper: FakeBrowserRefreshSleeper = FakeBrowserRefreshSleeper()) -> ClaudeTranscriptStore {
        ClaudeTranscriptStore(rpc: rpc, sleeper: sleeper)
    }

    @MainActor
    private func openWithLatest(
        _ store: ClaudeTranscriptStore,
        _ rpc: DocumentRPCStub,
        session: ClaudeSessionSummary = TranscriptFixtures.session(),
        entries: [ClaudeTranscriptEntry],
        before: Int64?
    ) async throws {
        await rpc.enqueue(.response(try F.pageResponse(entries, before: before, sessionID: session.sessionId)), for: F.page)
        await store.open(session)
    }

    // MARK: sessions

    @Test @MainActor
    func testSessionsAreSortedNewestFirst() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        await rpc.enqueue(.response(try F.sessionsResponse([
            F.session("old", modifiedAt: 100),
            F.session("new", status: "live", modifiedAt: 300),
            F.session("unknown", modifiedAt: nil),
            F.session("middle", modifiedAt: 200),
        ])), for: F.list)

        await store.loadSessions()

        #expect(store.sessionsState == .loaded)
        #expect(store.sessions.map(\.sessionId) == ["new", "middle", "old", "unknown"])
        #expect(await rpc.params(method: F.list) == [.object([:])])
    }

    @Test @MainActor
    func testMethodNotFoundMarksUnsupportedAndStopsCalling() async {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        await rpc.enqueue(.response(F.error(RemoteErrorCode.methodNotFound.rawValue)), for: F.list)

        await store.loadSessions()
        await store.loadSessions()

        #expect(store.isUnsupported)
        #expect(store.sessions.isEmpty)
        #expect(await rpc.callCount(method: F.list) == 1)
    }

    @Test @MainActor
    func testRelayWithoutTranscriptCapabilityHidesHistory() async {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-transcript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let routingRPC = OfflineRPCDispatch()
        let coordinator = RemoteFileFeatureCoordinator(
            routingRPC: routingRPC,
            attachments: AttachmentCoordinator(store: AttachmentStore(rpc: routingRPC), photoStager: FoundationAttachmentPhotoStager()),
            terminalArtifacts: TerminalArtifactStore(rpc: routingRPC, cache: TerminalArtifactCache(rootURL: cacheRoot))
        )

        await coordinator.connect(rpc: DemoRPCDispatch(fileFeatureFixturesEnabled: true, feedScenario: "pending"), hostID: "r1-relay", accountScope: "account")
        #expect(coordinator.feedEnabled)
        #expect(!coordinator.transcriptEnabled)
        #expect(coordinator.agentsEnabled)

        await coordinator.connect(rpc: DemoRPCDispatch(fileFeatureFixturesEnabled: true), hostID: "w3-relay", accountScope: "account")
        #expect(!coordinator.agentsEnabled)

        await coordinator.connect(rpc: DemoRPCDispatch(fileFeatureFixturesEnabled: true, transcriptScenario: "sessions"), hostID: "relay", accountScope: "account")
        #expect(coordinator.transcriptEnabled)
        #expect(coordinator.agentsEnabled)
        await coordinator.transcripts.loadSessions()
        #expect(coordinator.transcripts.sessions.count == 4)

        await coordinator.connect(rpc: DemoRPCDispatch(fileFeatureFixturesEnabled: true, transcriptScenario: "method-not-found"), hostID: "relay", accountScope: "account")
        #expect(coordinator.transcriptEnabled)
        await coordinator.transcripts.loadSessions()
        #expect(!coordinator.transcriptEnabled)
        #expect(!coordinator.agentsEnabled)
    }

    // MARK: pages

    @Test @MainActor
    func testOpenShowsLatestThenOlderPageAttachesAboveWithAnchor() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        try await openWithLatest(store, rpc, entries: F.users(["e3", "e4"]), before: 200)
        #expect(store.transcriptState == .loaded)
        #expect(store.timeline.rows.map(\.id) == ["e3", "e4"])
        #expect(store.latestSequence == 1)

        await rpc.enqueue(.response(try F.pageResponse(F.users(["e1", "e2"]), before: nil)), for: F.page)
        await store.loadOlder()

        #expect(store.timeline.rows.map(\.id) == ["e1", "e2", "e3", "e4"])
        #expect(store.timeline.reachedStart)
        #expect(store.prependAnchorID == "e3")
        #expect(store.prependSequence == 1)
        #expect(!store.isLoadingOlder)
        #expect(try F.requests(await rpc.params(method: F.page)) == [
            ClaudeTranscriptPageRequest(sessionId: F.sessionID),
            ClaudeTranscriptPageRequest(sessionId: F.sessionID, before: 200),
        ])

        await store.loadOlder()
        #expect(await rpc.callCount(method: F.page) == 2)
    }

    @Test @MainActor
    func testOlderPageWaitsForTheAttachSignal() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        try await openWithLatest(store, rpc, entries: F.users(["e3"]), before: 200)
        await rpc.enqueue(.response(try F.pageResponse(F.users(["e1", "e2"]), before: nil)), for: F.page)
        let signal = AttachSignal()

        let loading = Task { await store.loadOlder(attachWhen: { await signal.wait() }) }
        await signal.waitUntilReached()
        #expect(store.timeline.rows.map(\.id) == ["e3"])
        #expect(store.isLoadingOlder)
        #expect(store.prependSequence == 0)

        signal.open()
        await loading.value
        #expect(store.timeline.rows.map(\.id) == ["e1", "e2", "e3"])
        #expect(store.prependSequence == 1)
        #expect(!store.isLoadingOlder)
    }

    @Test @MainActor
    func testEmptyOlderPagesContinueAtMostThreeTimes() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        try await openWithLatest(store, rpc, entries: F.users(["e9"]), before: 900)
        for before: Int64 in [800, 700, 600] {
            await rpc.enqueue(.response(try F.pageResponse([], before: before)), for: F.page)
        }

        await store.loadOlder()

        #expect(await rpc.callCount(method: F.page) == 4)
        #expect(store.timeline.rows.map(\.id) == ["e9"])
        #expect(store.timeline.olderBefore == 600)
        #expect(store.prependSequence == 0)
        #expect(!store.isLoadingOlder)

        await rpc.enqueue(.response(try F.pageResponse(F.users(["e5"]), before: nil)), for: F.page)
        await store.loadOlder()
        #expect(store.timeline.rows.map(\.id) == ["e5", "e9"])
        #expect(try F.requests(await rpc.params(method: F.page)).map(\.before) == [nil, 900, 800, 700, 600])
    }

    @Test @MainActor
    func testInvalidBeforeStartsAgainFromTheLatestPage() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        try await openWithLatest(store, rpc, entries: F.users(["e3"]), before: 200)
        await rpc.enqueue(.response(F.error(RemoteErrorCode.invalidField.rawValue, field: "before")), for: F.page)
        await rpc.enqueue(.response(try F.pageResponse(F.users(["e7", "e8"]), before: 600)), for: F.page)

        await store.loadOlder()

        #expect(store.transcriptState == .loaded)
        #expect(store.timeline.rows.map(\.id) == ["e7", "e8"])
        #expect(store.timeline.olderBefore == 600)
        #expect(store.olderFailure == nil)
        #expect(try F.requests(await rpc.params(method: F.page)).map(\.before) == [nil, 200, nil])
    }

    @Test @MainActor
    func testSessionNotFoundShowsNotFoundWithoutRetry() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        await rpc.enqueue(.response(F.error(RemoteErrorCode.claudeSessionNotFound.rawValue, field: "session_id")), for: F.page)

        await store.open(F.session())

        #expect(store.transcriptState == .failed(.sessionNotFound))
        #expect(!ClaudeTranscriptFailure.sessionNotFound.canRetry)
        #expect(store.timeline.rows.isEmpty)
    }

    @Test @MainActor
    func testTemporarilyUnavailableKeepsRowsAndRetrySucceeds() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        await rpc.enqueue(.response(F.error("temporarily_unavailable")), for: F.page)
        await store.open(F.session())
        #expect(store.transcriptState == .failed(.temporarilyUnavailable))
        #expect(ClaudeTranscriptFailure.temporarilyUnavailable.canRetry)

        await rpc.enqueue(.response(try F.pageResponse(F.users(["e3"]), before: 200)), for: F.page)
        await store.reloadLatest()
        #expect(store.transcriptState == .loaded)

        await rpc.enqueue(.response(F.error("temporarily_unavailable")), for: F.page)
        await store.loadOlder()
        #expect(store.olderFailure == .temporarilyUnavailable)
        #expect(store.transcriptState == .loaded)
        #expect(store.timeline.rows.map(\.id) == ["e3"])

        await rpc.enqueue(.response(try F.pageResponse(F.users(["e2"]), before: nil)), for: F.page)
        await store.loadOlder()
        #expect(store.olderFailure == nil)
        #expect(store.timeline.rows.map(\.id) == ["e2", "e3"])
    }

    @Test @MainActor
    func testResponseAfterCloseIsDropped() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        await rpc.enqueue(.gate("latest"), for: F.page)
        let opening = Task { await store.open(F.session()) }
        await rpc.waitUntilReached("latest")

        store.close()
        await rpc.release("latest", with: try F.pageResponse(F.users(["e1"]), before: nil))
        await opening.value

        #expect(store.openSession == nil)
        #expect(store.timeline.rows.isEmpty)
        #expect(store.transcriptState == .idle)
    }

    // MARK: live

    @Test @MainActor
    func testLiveLoopChecksTheLatestPageEveryTenSecondsUntilCancelled() async throws {
        let rpc = DocumentRPCStub()
        let sleeper = FakeBrowserRefreshSleeper()
        let store = makeStore(rpc, sleeper: sleeper)
        try await openWithLatest(store, rpc, session: F.session(status: "live"), entries: F.users(["e1", "e2"]), before: nil)

        let loop = Task { await store.runLiveLoop(isConnected: true, isActive: true, isNearBottom: true) }
        await sleeper.waitForRequests(1)
        #expect(await sleeper.requested == [ClaudeTranscriptRefreshPolicy.liveCheckSeconds])
        #expect(ClaudeTranscriptRefreshPolicy.liveCheckSeconds == 10)
        #expect(await rpc.callCount(method: F.page) == 1)

        await rpc.enqueue(.response(try F.pageResponse(F.users(["e1", "e2", "e3"]), before: nil)), for: F.page)
        await sleeper.fireNext()
        await sleeper.waitForRequests(2)
        #expect(store.timeline.rows.map(\.id) == ["e1", "e2", "e3"])
        #expect(store.latestSequence == 2)

        loop.cancel()
        await loop.value
        #expect(await rpc.callCount(method: F.page) == 2)
        #expect(await sleeper.pendingCount == 0)
    }

    @Test @MainActor
    func testLiveLoopDoesNotStartUnlessLiveVisibleAndAtTheBottom() async throws {
        let rpc = DocumentRPCStub()
        let sleeper = FakeBrowserRefreshSleeper()
        let store = makeStore(rpc, sleeper: sleeper)
        try await openWithLatest(store, rpc, session: F.session(status: "idle"), entries: F.users(["e1"]), before: nil)
        await store.runLiveLoop(isConnected: true, isActive: true, isNearBottom: true)

        try await openWithLatest(store, rpc, session: F.session(status: "live"), entries: F.users(["e1"]), before: nil)
        await store.runLiveLoop(isConnected: true, isActive: true, isNearBottom: false)
        await store.runLiveLoop(isConnected: true, isActive: false, isNearBottom: true)
        await store.runLiveLoop(isConnected: false, isActive: true, isNearBottom: true)

        #expect(await sleeper.requested.isEmpty)
        #expect(await rpc.callCount(method: F.page) == 2)
    }

    @Test @MainActor
    func testManualRefreshAppendsNewMessages() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        try await openWithLatest(store, rpc, entries: F.users(["e1"]), before: 100)
        await rpc.enqueue(.response(try F.pageResponse(F.users(["e1", "e2"]), before: nil)), for: F.page)

        await store.refreshLatest()

        #expect(store.timeline.rows.map(\.id) == ["e1", "e2"])
        #expect(store.latestSequence == 2)
    }
}
