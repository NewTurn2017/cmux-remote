import Foundation
import SharedKit
import Testing
@testable import CmuxRemote

@Suite("FeedStoreTests", .serialized, .timeLimit(.minutes(1)))
struct FeedStoreTests {
    private let list = FeedFixtures.list
    private let reply = FeedFixtures.reply

    @MainActor
    private func makeStore(_ rpc: DocumentRPCStub, sleeper: FakeBrowserRefreshSleeper = FakeBrowserRefreshSleeper()) -> FeedStore {
        FeedStore(rpc: rpc, sleeper: sleeper, now: { BrowserFixtures.fixedNow })
    }

    @MainActor
    private func startLoop(_ store: FeedStore) -> Task<Void, Never> {
        Task { await store.runRefreshLoop(intervalSeconds: 3, isConnected: true, isActive: true) }
    }

    // MARK: polling

    @Test @MainActor
    func testDisconnectedOrInactiveLoopSendsNoList() async {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)

        await store.runRefreshLoop(intervalSeconds: 3, isConnected: true, isActive: false)
        #expect(await rpc.callCount(method: list) == 0)
        #expect(store.state == .idle)

        await store.runRefreshLoop(intervalSeconds: 3, isConnected: false, isActive: true)
        #expect(await rpc.callCount(method: list) == 0)
        #expect(store.state == .failed(.disconnected))
    }

    @Test @MainActor
    func testLoopListsThenWaitsIntervalAndStopsOnCancel() async throws {
        let rpc = DocumentRPCStub()
        let sleeper = FakeBrowserRefreshSleeper()
        let store = makeStore(rpc, sleeper: sleeper)
        await rpc.enqueue(.response(try FeedFixtures.listResponse([FeedFixtures.permission()], truncated: true, omittedCount: 2)), for: list)

        let loop = startLoop(store)
        await sleeper.waitForRequests(1)
        #expect(await sleeper.requested == [3])
        #expect(store.state == .loaded)
        #expect(store.items.map(\.requestId) == ["perm"])
        #expect(store.pendingCount == 3)
        #expect(await rpc.params(method: list) == [.object([:])])

        await rpc.enqueue(.gate("l2"), for: list)
        await sleeper.fireNext()
        await rpc.waitUntilReached("l2")
        #expect(await rpc.callCount(method: list) == 2)

        loop.cancel()
        await rpc.release("l2", with: try FeedFixtures.listResponse([]))
        await loop.value
        #expect(await rpc.callCount(method: list) == 2)
        #expect(await sleeper.pendingCount == 0)
    }

    @Test @MainActor
    func testListFailureKeepsItemsAndBacksOff() async throws {
        let rpc = DocumentRPCStub()
        let sleeper = FakeBrowserRefreshSleeper()
        let store = makeStore(rpc, sleeper: sleeper)
        await rpc.enqueue(.response(try FeedFixtures.listResponse([FeedFixtures.permission()])), for: list)
        await rpc.enqueue(.response(FeedFixtures.error("temporarily_unavailable")), for: list)

        let loop = startLoop(store)
        await sleeper.waitForRequests(1)
        await sleeper.fireNext()
        await sleeper.waitForRequests(2)
        #expect(await sleeper.requested == [3, 6])
        #expect(store.state == .failed(.temporarilyUnavailable))
        #expect(store.items.map(\.requestId) == ["perm"])

        loop.cancel()
        await loop.value
    }

    @Test @MainActor
    func testMethodNotFoundMarksUnsupportedAndStops() async throws {
        let rpc = DocumentRPCStub()
        let sleeper = FakeBrowserRefreshSleeper()
        let store = makeStore(rpc, sleeper: sleeper)
        await rpc.enqueue(.response(FeedFixtures.error(RemoteErrorCode.methodNotFound.rawValue)), for: list)

        await store.runRefreshLoop(intervalSeconds: 3, isConnected: true, isActive: true)
        #expect(store.state == .unsupported)
        #expect(await sleeper.requested.isEmpty)

        await store.refresh(fresh: true)
        await store.reply(FeedReplyPolicy.request(for: .allowOnce, item: FeedFixtures.permission()))
        #expect(await rpc.callCount(method: list) == 1)
        #expect(await rpc.callCount(method: reply) == 0)
    }

    @Test @MainActor
    func testMissingCapabilityHidesFeedAndMethodNotFoundHidesItLater() async {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-feed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let routingRPC = OfflineRPCDispatch()
        let coordinator = RemoteFileFeatureCoordinator(
            routingRPC: routingRPC,
            attachments: AttachmentCoordinator(store: AttachmentStore(rpc: routingRPC), photoStager: FoundationAttachmentPhotoStager()),
            terminalArtifacts: TerminalArtifactStore(rpc: routingRPC, cache: TerminalArtifactCache(rootURL: cacheRoot))
        )

        await coordinator.connect(rpc: DemoRPCDispatch(), hostID: "old-relay", accountScope: "account")
        #expect(!coordinator.feedEnabled)

        await coordinator.connect(rpc: DemoRPCDispatch(fileFeatureFixturesEnabled: true), hostID: "w3-relay", accountScope: "account")
        #expect(!coordinator.feedEnabled)

        await coordinator.connect(rpc: DemoRPCDispatch(fileFeatureFixturesEnabled: true, feedScenario: "pending"), hostID: "relay", accountScope: "account")
        #expect(coordinator.feedEnabled)
        await coordinator.feed.refresh()
        #expect(coordinator.feed.pendingCount == 5)

        await coordinator.connect(rpc: DemoRPCDispatch(fileFeatureFixturesEnabled: true, feedScenario: "method-not-found"), hostID: "relay", accountScope: "account")
        #expect(coordinator.feedEnabled)
        await coordinator.feed.refresh()
        #expect(!coordinator.feedEnabled)
        #expect(coordinator.feed.items.isEmpty)
    }

    // MARK: replies

    @Test @MainActor
    func testSixButtonsSendExactReplyParams() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        let cases: [(FeedPendingItem, FeedReplyButton, String)] = [
            (FeedFixtures.permission("p-once"), .allowOnce, "once"),
            (FeedFixtures.permission("p-always"), .allowAlways, "always"),
            (FeedFixtures.permission("p-deny"), .deny, "deny"),
            (FeedFixtures.plan("plan-approve", defaultMode: "manual"), .approve, "manual"),
            (FeedFixtures.plan("plan-auto"), .autoApprove, "autoAccept"),
            (FeedFixtures.plan("plan-reject"), .reject, "deny"),
        ]
        for (item, button, _) in cases {
            await rpc.enqueue(.response(try FeedFixtures.replyResponse(item.requestId, kind: item.kind)), for: reply)
            await rpc.enqueue(.response(try FeedFixtures.listResponse([])), for: list)
            await store.reply(FeedReplyPolicy.request(for: button, item: item))
        }

        let expected: [JSONValue] = cases.map { item, _, mode in
            .object([
                "request_id": .string(item.requestId),
                "kind": .string(item.kind.rawValue),
                "mode": .string(mode),
            ])
        }
        #expect(await rpc.params(method: reply) == expected)
    }

    @Test @MainActor
    func testQuestionReplySendsSelectionsOnly() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        var draft = FeedQuestionDraft(questions: [FeedFixtures.singleSelect("q1", labels: ["A", "B"]), FeedFixtures.singleSelect("q2", labels: ["X", "Y"])])
        draft.toggle(question: 0, option: 0)
        draft.toggle(question: 1, option: 1)
        guard case .ready(let selections) = draft.outcome else {
            Issue.record("draft should be ready")
            return
        }
        await rpc.enqueue(.response(try FeedFixtures.replyResponse("question", kind: .question)), for: reply)
        await rpc.enqueue(.response(try FeedFixtures.listResponse([])), for: list)

        await store.reply(FeedReplyRequest(requestId: "question", kind: .question, selections: selections))

        #expect(await rpc.params(method: reply) == [.object([
            "request_id": .string("question"),
            "kind": .string("question"),
            "selections": .array([.string("A"), .string("Y")]),
        ])])
    }

    @Test @MainActor
    func testDuplicateTapSendsOneReply() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        let request = FeedReplyPolicy.request(for: .allowOnce, item: FeedFixtures.permission())
        await rpc.enqueue(.gate("r1"), for: reply)
        await rpc.enqueue(.response(try FeedFixtures.listResponse([])), for: list)

        let first = Task { await store.reply(request) }
        await rpc.waitUntilReached("r1")
        #expect(store.isBusy("perm"))
        await store.reply(request)
        await store.reply(request)
        #expect(await rpc.callCount(method: reply) == 1)

        await rpc.release("r1", with: try FeedFixtures.replyResponse("perm", kind: .permission))
        await first.value
        #expect(!store.isBusy("perm"))
        #expect(await rpc.callCount(method: reply) == 1)
    }

    @Test @MainActor
    func testSuccessfulReplyRemovesItemAndHidesItFromStaleList() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        let permission = FeedFixtures.permission()
        let question = FeedFixtures.question()
        await rpc.enqueue(.response(try FeedFixtures.listResponse([permission, question])), for: list)
        await store.refresh()
        #expect(store.pendingCount == 2)

        await rpc.enqueue(.response(try FeedFixtures.replyResponse("perm", kind: .permission)), for: reply)
        await rpc.enqueue(.response(try FeedFixtures.listResponse([permission, question])), for: list)
        await store.reply(FeedReplyPolicy.request(for: .deny, item: permission))

        #expect(await rpc.callCount(method: list) == 2)
        #expect(store.items.map(\.requestId) == ["question"])
        #expect(store.notice == nil)
        #expect(store.replyFailures.isEmpty)
    }

    @Test @MainActor
    func testNotPendingShowsAlreadyHandledAndRemovesItem() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        let permission = FeedFixtures.permission()
        await rpc.enqueue(.response(try FeedFixtures.listResponse([permission])), for: list)
        await store.refresh()

        await rpc.enqueue(.response(FeedFixtures.error(RemoteErrorCode.feedRequestNotPending.rawValue)), for: reply)
        await rpc.enqueue(.response(try FeedFixtures.listResponse([permission])), for: list)
        await store.reply(FeedReplyPolicy.request(for: .allowOnce, item: permission))

        #expect(store.notice == .alreadyHandled)
        #expect(store.items.isEmpty)
        #expect(await rpc.callCount(method: reply) == 1)
    }

    @Test @MainActor
    func testUnknownReplyOutcomeIsVerifiedByListNotResent() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        let delivered = FeedFixtures.permission("delivered")
        let lost = FeedFixtures.permission("lost")
        await rpc.enqueue(.response(try FeedFixtures.listResponse([delivered, lost])), for: list)
        await store.refresh()

        await rpc.enqueue(.response(FeedFixtures.error("temporarily_unavailable")), for: reply)
        await rpc.enqueue(.response(try FeedFixtures.listResponse([lost])), for: list)
        await store.reply(FeedReplyPolicy.request(for: .allowOnce, item: delivered))
        #expect(store.items.map(\.requestId) == ["lost"])
        #expect(store.replyFailures["delivered"] == nil)
        #expect(store.notice == nil)

        await rpc.enqueue(.response(FeedFixtures.error("temporarily_unavailable")), for: reply)
        await rpc.enqueue(.response(try FeedFixtures.listResponse([lost])), for: list)
        await store.reply(FeedReplyPolicy.request(for: .allowOnce, item: lost))
        #expect(store.items.map(\.requestId) == ["lost"])
        #expect(store.replyFailures["lost"] == .notConfirmed)
        #expect(!store.isBusy("lost"))

        #expect(await rpc.callCount(method: reply) == 2)
        #expect(await rpc.callCount(method: list) == 3)
    }

    @Test @MainActor
    func testVerificationIgnoresListStartedBeforeTheReply() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        let permission = FeedFixtures.permission()
        await rpc.enqueue(.gate("early-list"), for: list)
        let earlyList = Task { await store.refresh() }
        await rpc.waitUntilReached("early-list")

        await rpc.enqueue(.gate("r1"), for: reply)
        await rpc.enqueue(.response(try FeedFixtures.listResponse([])), for: list)
        let replyTask = Task { await store.reply(FeedReplyPolicy.request(for: .allowOnce, item: permission)) }
        await rpc.waitUntilReached("r1")
        await rpc.release("r1", with: FeedFixtures.error("temporarily_unavailable"))
        await waitUntil { store.notice == .verifying }
        await rpc.release("early-list", with: try FeedFixtures.listResponse([permission]))
        await earlyList.value
        await replyTask.value

        #expect(store.replyFailures["perm"] == nil)
        #expect(store.items.isEmpty)
        #expect(await rpc.callCount(method: list) == 2)
    }

    @Test @MainActor
    func testRejectedReplyKeepsItemAndAllowsRetry() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        let permission = FeedFixtures.permission()
        await rpc.enqueue(.response(try FeedFixtures.listResponse([permission])), for: list)
        await store.refresh()

        await rpc.enqueue(.response(FeedFixtures.error(RemoteErrorCode.invalidField.rawValue)), for: reply)
        await store.reply(FeedReplyPolicy.request(for: .allowOnce, item: permission))

        #expect(store.replyFailures["perm"] == .rejected)
        #expect(store.items.map(\.requestId) == ["perm"])
        #expect(!store.isBusy("perm"))
        #expect(await rpc.callCount(method: list) == 1)
    }
}
