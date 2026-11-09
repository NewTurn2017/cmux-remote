import Foundation
import SharedKit
import Testing
@testable import RelayServer

@Suite("FeedServiceTests")
struct FeedServiceTests {
    private static let start = Date(timeIntervalSince1970: 1_794_240_000)

    private func service(_ cmux: FakeFeedCMUX, log: BrowserLogRecorder = BrowserLogRecorder()) -> FeedService {
        FeedService(dispatch: cmux.dispatch, clock: { Self.start }, log: { log.record($0) })
    }

    private func roundTrip(_ result: FeedPendingListResult) throws -> FeedPendingListResult {
        try SharedKitJSON.snakeCaseDecoder.decode(FeedPendingListResult.self, from: SharedKitJSON.snakeCaseEncoder.encode(result))
    }

    // MARK: - Filtering and translation

    @Test func pendingKeepsOnlyResolvableItemsNewestFirst() async throws {
        let cmux = FakeFeedCMUX(items: [
            FeedRaw.item(id: "telemetry", kind: "toolUse", status: "telemetry"),
            FeedRaw.item(id: "expired", kind: "question", status: "expired", requestId: "r-expired"),
            FeedRaw.item(id: "resolved", kind: "permissionRequest", status: "resolved", requestId: "r-resolved"),
            FeedRaw.item(id: "no-request", kind: "question"),
            FeedRaw.item(id: "unknown", kind: "toolUse", requestId: "r-unknown"),
            .object(["id": .string("no-workstream"), "source": .string("claude"), "kind": .string("question"),
                     "status": .string("pending"), "request_id": .string("r-x")]),
            FeedRaw.item(id: "question", kind: "question", requestId: "req-q", createdAt: "2026-11-09T10:00:01Z"),
            FeedRaw.item(id: "permission", kind: "permissionRequest", requestId: "req-p", createdAt: "2026-11-09T10:00:03Z"),
            FeedRaw.item(id: "plan", kind: "exitPlan", requestId: "req-x", createdAt: "2026-11-09T10:00:02Z", source: "codex"),
        ])
        let log = BrowserLogRecorder()

        let result = try await service(cmux, log: log).pending(limit: FeedLimits.defaultListLimit)

        #expect(result.items.map(\.id) == ["permission", "plan", "question"])
        #expect(result.items.map(\.kind) == [.permission, .plan, .question])
        #expect(result.items.map(\.createdAt) == [1_794_218_403_000, 1_794_218_402_000, 1_794_218_401_000])
        #expect(result.items[1].source == "codex")
        #expect(result.truncated == false)
        #expect(result.omittedCount == nil)
        #expect(await cmux.params(of: "feed.list") == [.object(["pending_only": .bool(true)])])
        #expect(log.lines == ["feed.pending.list dropped: malformed=1 not_pending=3 no_request_id=1 unknown_kind=1"])
        #expect(try roundTrip(result) == result)
    }

    @Test func questionItemsFollowTheTuiQuestionRules() async throws {
        let cmux = FakeFeedCMUX(items: [
            FeedRaw.item(id: "multi", kind: "question", requestId: "req-multi", [
                "questions": .array([
                    .object(["id": .string("q1"), "question": .string("Which?"), "multi_select": .bool(false),
                             "options": .array([FeedRaw.option("a", "A"), FeedRaw.option("b", "B")])]),
                    .object(["header": .string("Pick many"), "multiSelect": .bool(true),
                             "options": .array([FeedRaw.option("x", "X"), .object(["label": .string("no id")])])]),
                    .object(["id": .string("q3"), "prompt": .string("Free text")]),
                    .object([:]),
                ]),
            ]),
            FeedRaw.item(id: "legacy", kind: "question", requestId: "req-legacy", createdAt: "2026-11-09T09:00:00Z", [
                "question_prompt": .string("Legacy?"), "question_multi_select": .bool(true),
                "question_options": .array([FeedRaw.option("y", "Yes")]),
            ]),
            FeedRaw.item(id: "title-only", kind: "question", requestId: "req-title", createdAt: "2026-11-09T08:00:00Z", [
                "questions": .array([]), "title": .string("Title only"),
            ]),
        ])

        let result = try await service(cmux).pending(limit: FeedLimits.defaultListLimit)
        let byID = Dictionary(uniqueKeysWithValues: result.items.map { ($0.id, $0) })

        let multi = try #require(byID["multi"]?.questions)
        #expect(multi.map(\.id) == ["q1", "question-2", "q3"])
        #expect(multi.map(\.prompt) == ["Which?", "Pick many", "Free text"])
        #expect(multi.map(\.multiSelect) == [false, true, false])
        #expect(multi.map { $0.options.map(\.label) } == [["A", "B"], ["X"], []])

        let legacy = try #require(byID["legacy"]?.questions)
        #expect(legacy == [FeedQuestion(id: "question-1", prompt: "Legacy?", multiSelect: true, options: [FeedOption(id: "y", label: "Yes")])])

        let titleOnly = try #require(byID["title-only"]?.questions)
        #expect(titleOnly == [FeedQuestion(id: "question-1", prompt: "Title only", multiSelect: false, options: [])])

        let wire = try JSONSerialization.jsonObject(with: SharedKitJSON.snakeCaseEncoder.encode(try #require(byID["multi"]))) as? [String: Any]
        let freeText = try #require((wire?["questions"] as? [[String: Any]])?.last)
        #expect(Set(freeText.keys) == ["id", "prompt", "multi_select", "options"])
        #expect((freeText["options"] as? [Any])?.isEmpty == true)
        #expect(freeText["multi_select"] as? Bool == false)
        #expect(try roundTrip(result) == result)
    }

    @Test func permissionAndPlanItemsCarryModesAndText() async throws {
        let cmux = FakeFeedCMUX(items: [
            FeedRaw.item(id: "perm-object", kind: "permissionRequest", requestId: "req-po", createdAt: "2026-11-09T10:00:05Z", [
                "tool_name": .string("Bash"),
                "tool_input": .object(["command": .string("ls -la /tmp"), "b": .int(1), "a": .object(["z": .bool(true)])]),
            ]),
            FeedRaw.item(id: "perm-string", kind: "permissionRequest", requestId: "req-ps", createdAt: "2026-11-09T10:00:04Z", [
                "tool_input": .string(#"{"command":"npm test"}"#),
            ]),
            FeedRaw.item(id: "plan-summary", kind: "exitPlan", requestId: "req-x1", createdAt: "2026-11-09T10:00:03Z", [
                "plan_summary": .string("Summary"), "plan": .string("Full plan"), "default_mode": .string("autoAccept"),
            ]),
            FeedRaw.item(id: "plan-full", kind: "exitPlan", requestId: "req-x2", createdAt: "2026-11-09T10:00:02Z", [
                "plan": .string("Full plan"), "default_mode": .string("bypassPermissions"),
            ]),
        ])

        let result = try await service(cmux).pending(limit: FeedLimits.defaultListLimit)
        let byID = Dictionary(uniqueKeysWithValues: result.items.map { ($0.id, $0) })

        let object = try #require(byID["perm-object"])
        #expect(object.toolName == "Bash")
        #expect(object.toolInput == #"{"a":{"z":true},"b":1,"command":"ls -la /tmp"}"#)
        #expect(object.toolInputTruncated == nil)
        #expect(object.availableModes == ["once", "always", "deny"])
        #expect(object.questions == nil && object.planText == nil)
        #expect(byID["perm-string"]?.toolInput == #"{"command":"npm test"}"#)
        #expect(byID["perm-string"]?.toolName == nil)

        let summary = try #require(byID["plan-summary"])
        #expect(summary.planText == "Summary")
        #expect(summary.defaultMode == "autoAccept")
        #expect(summary.availableModes == ["autoAccept", "manual", "deny"])
        #expect(summary.planTextTruncated == nil)
        #expect(byID["plan-full"]?.planText == "Full plan")
        #expect(byID["plan-full"]?.defaultMode == nil)
        #expect(try roundTrip(result) == result)
    }

    @Test func longTextIsCutAtTheContractLimitsAndStillDecodes() async throws {
        let toolInput = String(repeating: "가a😀", count: 3_000)
        let plan = String(repeating: "\"\\\n", count: 30_000)
        let cmux = FakeFeedCMUX(items: [
            FeedRaw.item(id: "perm", kind: "permissionRequest", requestId: "req-p", createdAt: "2026-11-09T10:00:03Z", [
                "title": .string(String(repeating: "한", count: 600)),
                "cwd": .string(String(repeating: "c", count: 1_100)),
                "tool_name": .string(String(repeating: "T", count: 200)),
                "tool_input": .string(toolInput),
            ]),
            FeedRaw.item(id: "plan", kind: "exitPlan", requestId: "req-x", createdAt: "2026-11-09T10:00:02Z", ["plan": .string(plan)]),
            FeedRaw.item(id: "question", kind: "question", requestId: "req-q", createdAt: "2026-11-09T10:00:01Z", [
                "questions": .array([FeedRaw.question("q1", prompt: String(repeating: "p", count: 3_000), options: [])]),
            ]),
        ])

        let result = try await service(cmux).pending(limit: FeedLimits.defaultListLimit)
        let byID = Dictionary(uniqueKeysWithValues: result.items.map { ($0.id, $0) })

        let permission = try #require(byID["perm"])
        #expect(permission.title?.count == FeedLimits.maxTitleCharacters)
        #expect(permission.cwd?.count == FeedLimits.maxCwdCharacters)
        #expect(permission.toolName?.count == FeedLimits.maxToolNameCharacters)
        let cutInput = try #require(permission.toolInput)
        #expect(cutInput.utf8.count <= FeedLimits.maxToolInputBytes)
        #expect(cutInput.utf8.count > FeedLimits.maxToolInputBytes - 4)
        #expect(toolInput.hasPrefix(cutInput))
        #expect(permission.toolInputTruncated == true)

        let planItem = try #require(byID["plan"])
        #expect((planItem.planText?.utf8.count ?? 0) <= FeedLimits.maxPlanTextBytes)
        #expect(planItem.planTextTruncated == true)
        #expect(byID["question"]?.questions?.first?.prompt.utf8.count == FeedLimits.maxQuestionPromptBytes)
        #expect(try roundTrip(result) == result)
    }

    @Test func questionItemsBeyondLabelIdOrCountLimitsAreDroppedNotCut() async throws {
        let label512 = String(repeating: "L", count: FeedLimits.maxOptionLabelCharacters)
        func question(_ id: String, _ options: [JSONValue]) -> JSONValue {
            FeedRaw.item(id: id, kind: "question", requestId: "req-\(id)", [
                "questions": .array([FeedRaw.question("q", prompt: "p", options: options)]),
            ])
        }
        let cmux = FakeFeedCMUX(items: [
            question("long-label", [FeedRaw.option("o", label512 + "L")]),
            question("long-option-id", [FeedRaw.option(String(repeating: "i", count: 257), "ok")]),
            question("many-options", (0...FeedLimits.maxOptionsPerQuestion).map { FeedRaw.option("o\($0)", "L\($0)") }),
            FeedRaw.item(id: "many-questions", kind: "question", requestId: "req-many-questions", [
                "questions": .array((0...FeedLimits.maxQuestions).map { FeedRaw.question("q\($0)", prompt: "p", options: []) }),
            ]),
            FeedRaw.item(id: "long-question-id", kind: "question", requestId: "req-long-question-id", [
                "questions": .array([FeedRaw.question(String(repeating: "q", count: 257), prompt: "p", options: [])]),
            ]),
            FeedRaw.item(id: "long-request-id", kind: "question", requestId: String(repeating: "r", count: 257)),
            question("at-limit", [FeedRaw.option("o", label512)]),
        ])
        let log = BrowserLogRecorder()

        let result = try await service(cmux, log: log).pending(limit: FeedLimits.defaultListLimit)

        #expect(result.items.map(\.id) == ["at-limit"])
        #expect(result.items.first?.questions?.first?.options.first?.label == label512)
        #expect(log.lines == ["feed.pending.list dropped: oversized_request_id=1 oversized_question=5"])
        #expect(try roundTrip(result) == result)
    }

    @Test func selectionRulesMatchTheAdjudication() {
        let single = FeedQuestion(id: "q", prompt: "p", multiSelect: false,
                                  options: [FeedOption(id: "a", label: "A"), FeedOption(id: "b", label: "B")])
        let multi = FeedQuestion(id: "m", prompt: "p", multiSelect: true,
                                 options: [FeedOption(id: "x", label: "X"), FeedOption(id: "y", label: "Y")])
        let empty = FeedQuestion(id: "e", prompt: "p", multiSelect: false, options: [])
        let second = FeedQuestion(id: "s", prompt: "p", multiSelect: false, options: [FeedOption(id: "y", label: "Y")])
        let cases: [([FeedQuestion], [String], Bool)] = [
            ([single], ["A"], true), ([single], ["A", "B"], false), ([single], [], false), ([single], ["Z"], false),
            ([multi], ["X", "Y"], true), ([multi], ["Y"], true), ([multi], [], false), ([multi], ["X", "X"], false),
            ([multi], ["Z"], false),
            ([empty], [], true), ([empty], ["A"], false),
            ([single, second], ["A", "Y"], true), ([single, second], ["Y", "A"], false), ([single, second], ["A"], false),
            ([single, multi], ["A", "X"], false), ([single, empty], ["A", ""], false), ([], [], false),
        ]
        for (questions, selections, expected) in cases {
            #expect(FeedItemTranslator.selectionsAnswer(questions, selections) == expected, "\(selections)")
        }
    }

    // MARK: - Replies

    @Test func replyMapsEachKindToItsCmuxMethodAndParams() async throws {
        let cmux = FakeFeedCMUX(items: [
            FeedRaw.singleQuestion(id: "question", requestId: "req-q", labels: ["A", "B"]),
            FeedRaw.item(id: "permission", kind: "permissionRequest", requestId: "req-p"),
            FeedRaw.item(id: "plan", kind: "exitPlan", requestId: "req-x"),
        ])
        let feed = service(cmux)

        #expect(try await feed.reply(FeedReplyRequest(requestId: "req-q", kind: .question, selections: ["B"]))
            == FeedReplyResult(requestId: "req-q", kind: .question))
        #expect(try await feed.reply(FeedReplyRequest(requestId: "req-p", kind: .permission, mode: "always"))
            == FeedReplyResult(requestId: "req-p", kind: .permission))
        #expect(try await feed.reply(FeedReplyRequest(requestId: "req-x", kind: .plan, mode: "manual"))
            == FeedReplyResult(requestId: "req-x", kind: .plan))

        let calls = await cmux.calls
        #expect(calls.map(\.method) == [
            "feed.list", "feed.question.reply", "feed.list", "feed.permission.reply", "feed.list", "feed.exit_plan.reply",
        ])
        #expect(calls[1].params == .object(["request_id": .string("req-q"), "selections": .array([.string("B")])]))
        #expect(calls[3].params == .object(["request_id": .string("req-p"), "mode": .string("always")]))
        #expect(calls[5].params == .object(["request_id": .string("req-x"), "mode": .string("manual")]))
    }

    @Test func replyRejectsModesKindsAndSelectionsOutsideThePendingItem() async throws {
        let cmux = FakeFeedCMUX(items: [
            FeedRaw.singleQuestion(id: "question", requestId: "req-q", labels: ["A", "B"]),
            FeedRaw.item(id: "multi", kind: "question", requestId: "req-m", [
                "questions": .array([
                    FeedRaw.question("q1", prompt: "p", options: [FeedRaw.option("a", "A")]),
                    FeedRaw.question("q2", prompt: "p", multiSelect: true, options: [FeedRaw.option("x", "X")]),
                ]),
            ]),
            FeedRaw.item(id: "permission", kind: "permissionRequest", requestId: "req-p"),
            FeedRaw.item(id: "plan", kind: "exitPlan", requestId: "req-x"),
        ])
        let feed = service(cmux)
        let rejected: [(FeedReplyRequest, FeedService.Error)] = [
            (FeedReplyRequest(requestId: "req-p", kind: .permission, mode: "bypass"), .invalidField("mode")),
            (FeedReplyRequest(requestId: "req-p", kind: .permission, mode: "all"), .invalidField("mode")),
            (FeedReplyRequest(requestId: "req-x", kind: .plan, mode: "bypassPermissions"), .invalidField("mode")),
            (FeedReplyRequest(requestId: "req-x", kind: .plan, mode: "ultraplan"), .invalidField("mode")),
            (FeedReplyRequest(requestId: "req-x", kind: .plan, mode: "once"), .invalidField("mode")),
            (FeedReplyRequest(requestId: "req-x", kind: .permission, mode: "once"), .invalidField("kind")),
            (FeedReplyRequest(requestId: "req-q", kind: .question, selections: ["A", "B"]), .invalidField("selections")),
            (FeedReplyRequest(requestId: "req-q", kind: .question, selections: ["Z"]), .invalidField("selections")),
            (FeedReplyRequest(requestId: "req-q", kind: .question, selections: []), .invalidField("selections")),
            (FeedReplyRequest(requestId: "req-m", kind: .question, selections: ["A", "X"]), .invalidField("selections")),
        ]
        for (request, expected) in rejected {
            await #expect(throws: expected) { try await feed.reply(request) }
        }
        #expect(await cmux.replyCount() == 0)
        #expect(await cmux.count(of: "feed.list") == rejected.count)
    }

    @Test func replyToARequestThatIsNoLongerPendingNeverCallsReply() async throws {
        let cmux = FakeFeedCMUX(items: [FeedRaw.item(id: "plan", kind: "exitPlan", requestId: "req-x")])
        let log = BrowserLogRecorder()

        await #expect(throws: FeedService.Error.notPending) {
            try await service(cmux, log: log).reply(FeedReplyRequest(requestId: "req-gone", kind: .plan, mode: "manual"))
        }
        #expect(await cmux.replyCount() == 0)
        #expect(await cmux.count(of: "feed.list") == 1)
        #expect(log.lines == ["feed.reply refused: not_pending"])
    }

    @Test func cmuxReplyErrorsMapRaceCodesToNotPendingAndKeepOthers() async throws {
        let cmux = FakeFeedCMUX(
            items: [
                FeedRaw.item(id: "permission", kind: "permissionRequest", requestId: "req-p"),
                FeedRaw.item(id: "plan", kind: "exitPlan", requestId: "req-x"),
                FeedRaw.singleQuestion(id: "question", requestId: "req-q", labels: ["A"]),
            ],
            replyFailures: [
                "feed.permission.reply": "not_found",
                "feed.exit_plan.reply": "rate_limited",
                "feed.question.reply": "unauthorized",
            ]
        )
        let log = BrowserLogRecorder()
        let feed = service(cmux, log: log)

        await #expect(throws: FeedService.Error.notPending) {
            try await feed.reply(FeedReplyRequest(requestId: "req-p", kind: .permission, mode: "once"))
        }
        await #expect(throws: FeedService.Error.native("rate_limited")) {
            try await feed.reply(FeedReplyRequest(requestId: "req-x", kind: .plan, mode: "deny"))
        }
        await #expect(throws: FeedService.Error.native("forbidden")) {
            try await feed.reply(FeedReplyRequest(requestId: "req-q", kind: .question, selections: ["A"]))
        }
        #expect(log.lines == [
            "feed.reply cmux error: code=not_found",
            "feed.reply cmux error: code=rate_limited",
            "feed.reply cmux error: code=unauthorized",
        ])
        #expect(FeedService.notPendingReplyCodes == ["not_found", "request_not_found", "not_pending", "already_resolved", "expired"])
    }

    @Test func overlappingRepliesForOneRequestRunOneAfterAnother() async throws {
        let replyGate = AsyncStream<Void>.makeStream()
        let replyEntered = AsyncStream<Void>.makeStream()
        let queued = AsyncStream<FeedService.Observation>.makeStream()
        defer { replyGate.continuation.finish() }
        let cmux = FakeFeedCMUX(
            items: [FeedRaw.singleQuestion(id: "question", requestId: "req-q", labels: ["A", "B"])],
            replyGate: replyGate.stream,
            replyEntered: replyEntered.continuation
        )
        let feed = FeedService(dispatch: cmux.dispatch, clock: { Self.start }, observe: { queued.continuation.yield($0) })

        let first = Task { try await feed.reply(FeedReplyRequest(requestId: "req-q", kind: .question, selections: ["A"])) }
        _ = try await nextEvent(replyEntered.stream)
        let second = Task { try await feed.reply(FeedReplyRequest(requestId: "req-q", kind: .question, selections: ["B"])) }
        #expect(try await nextEvent(queued.stream) == .replyQueued)
        replyGate.continuation.yield()

        #expect(try await first.value == FeedReplyResult(requestId: "req-q", kind: .question))
        await #expect(throws: FeedService.Error.notPending) { try await second.value }
        #expect(await cmux.replyCount() == 1)
        #expect(await cmux.params(of: "feed.question.reply") == [
            .object(["request_id": .string("req-q"), "selections": .array([.string("A")])]),
        ])
    }

    // MARK: - Sharing and reuse

    @Test func overlappingListRequestsShareOneCmuxCall() async throws {
        let listGate = AsyncStream<Void>.makeStream()
        let listEntered = AsyncStream<Void>.makeStream()
        let joined = AsyncStream<FeedService.Observation>.makeStream()
        defer { listGate.continuation.finish() }
        let cmux = FakeFeedCMUX(
            items: [FeedRaw.item(id: "plan", kind: "exitPlan", requestId: "req-x")],
            listGate: listGate.stream,
            listEntered: listEntered.continuation
        )
        let feed = FeedService(dispatch: cmux.dispatch, clock: { Self.start }, observe: { joined.continuation.yield($0) })

        let first = Task { try await feed.pending(limit: 50) }
        _ = try await nextEvent(listEntered.stream)
        let second = Task { try await feed.pending(limit: 50) }
        #expect(try await nextEvent(joined.stream) == .joinedInFlight)
        listGate.continuation.yield()

        let results = try await (first.value, second.value)
        #expect(results.0 == results.1)
        #expect(results.0.items.map(\.id) == ["plan"])
        #expect(await cmux.count(of: "feed.list") == 1)
    }

    @Test func successfulListIsReusedForOneSecondAndDroppedAfterAReply() async throws {
        let clock = BrowserTestClock(Self.start)
        let cmux = FakeFeedCMUX(items: [
            FeedRaw.item(id: "plan", kind: "exitPlan", requestId: "req-x"),
            FeedRaw.item(id: "permission", kind: "permissionRequest", requestId: "req-p"),
        ])
        let feed = FeedService(dispatch: cmux.dispatch, clock: { clock.now })

        let first = try await feed.pending(limit: 50)
        clock.advance(by: 0.75)
        #expect(try await feed.pending(limit: 50) == first)
        #expect(await cmux.count(of: "feed.list") == 1)

        clock.advance(by: 0.25)
        _ = try await feed.pending(limit: 50)
        #expect(await cmux.count(of: "feed.list") == 2)

        _ = try await feed.reply(FeedReplyRequest(requestId: "req-x", kind: .plan, mode: "autoAccept"))
        #expect(await cmux.count(of: "feed.list") == 3)
        let afterReply = try await feed.pending(limit: 50)
        #expect(afterReply.items.map(\.id) == ["permission"])
        #expect(await cmux.count(of: "feed.list") == 4)
    }

    @Test func listFailuresKeepTheirCodeAndAreNeverReused() async throws {
        let cmux = FakeFeedCMUX(items: [], listFailure: "rate_limited")
        let feed = service(cmux)
        for _ in 0..<2 {
            await #expect(throws: FeedService.Error.native("rate_limited")) { try await feed.pending(limit: 50) }
        }
        #expect(await cmux.count(of: "feed.list") == 2)

        let denied = FakeFeedCMUX(items: [], listFailure: "unauthorized")
        await #expect(throws: FeedService.Error.native("forbidden")) { try await service(denied).pending(limit: 50) }

        let malformed = FeedService(dispatch: { _, _ in .success(.object(["items": .string("x")])) }, clock: { Self.start })
        await #expect(throws: FeedService.Error.malformed) { try await malformed.pending(limit: 50) }
        let missingItems = FeedService(dispatch: { _, _ in .success(.object([:])) }, clock: { Self.start })
        #expect(try await missingItems.pending(limit: 50) == FeedPendingListResult(items: [], truncated: false))
    }

    // MARK: - Size budget

    @Test func pendingResultStaysUnderTheEncodedBudgetAndMarksTruncated() async throws {
        let escapedPlan = String(repeating: "\"\\", count: FeedLimits.maxPlanTextBytes / 2)
        let items = (0..<30).map { index in
            FeedRaw.item(id: String(format: "plan-%02d", index), kind: "exitPlan", requestId: "req-\(index)",
                         createdAt: String(format: "2026-11-09T10:00:%02dZ", index), ["plan": .string(escapedPlan)])
        }
        let cmux = FakeFeedCMUX(items: items)

        let result = try await service(cmux).pending(limit: FeedLimits.maxListLimit)
        let encoded = try SharedKitJSON.snakeCaseEncoder.encode(result)

        #expect(encoded.count <= FeedLimits.maxResponseBytes - FeedLimits.responseEnvelopeReserveBytes)
        #expect(result.truncated == true)
        #expect(!result.items.isEmpty)
        #expect(result.omittedCount == 30 - result.items.count)
        #expect(result.items.map(\.id) == (0..<result.items.count).map { String(format: "plan-%02d", 29 - $0) })
        #expect(try roundTrip(result) == result)

        let limited = try await service(cmux).pending(limit: 2)
        #expect(limited.items.map(\.id) == ["plan-29", "plan-28"])
        #expect(limited.truncated == false)
    }

    // MARK: - Privacy

    @Test func logsCarryNoFeedContent() async throws {
        let secret = "PRIVATE-SENTINEL"
        let cmux = FakeFeedCMUX(
            items: [
                FeedRaw.item(id: "question", kind: "question", requestId: "req-q", [
                    "title": .string("\(secret) title"), "cwd": .string("/Users/\(secret)/project"),
                    "questions": .array([FeedRaw.question("q1", prompt: "\(secret) prompt",
                                                          options: [FeedRaw.option("o1", "\(secret) label")])]),
                ]),
                FeedRaw.item(id: "permission", kind: "permissionRequest", requestId: "req-p", [
                    "tool_name": .string("\(secret)Tool"), "tool_input": .string("\(secret) input"),
                ]),
                FeedRaw.item(id: "plan", kind: "exitPlan", requestId: "req-x", ["plan": .string("\(secret) plan")]),
                FeedRaw.item(id: "bad", kind: "question", requestId: "req-bad", [
                    "questions": .array([FeedRaw.question("q", prompt: secret, options: [
                        FeedRaw.option("o", secret + String(repeating: "x", count: 600)),
                    ])]),
                ]),
                FeedRaw.item(id: "\(secret)-telemetry", kind: "toolUse", status: "telemetry", ["text": .string(secret)]),
            ],
            replyFailures: ["feed.exit_plan.reply": "\(secret)/code"]
        )
        let log = BrowserLogRecorder()
        let feed = service(cmux, log: log)

        _ = try await feed.pending(limit: 50)
        _ = try? await feed.reply(FeedReplyRequest(requestId: "req-q", kind: .question, selections: ["\(secret) wrong"]))
        _ = try await feed.reply(FeedReplyRequest(requestId: "req-q", kind: .question, selections: ["\(secret) label"]))
        _ = try? await feed.reply(FeedReplyRequest(requestId: "req-x", kind: .plan, mode: "deny"))
        _ = try? await feed.reply(FeedReplyRequest(requestId: "\(secret)-missing", kind: .plan, mode: "deny"))

        #expect(log.lines.count >= 4)
        #expect(log.lines.contains("feed.reply cmux error: code=other"))
        for line in log.lines {
            #expect(!line.contains(secret))
            #expect(!line.contains("/"))
        }
    }
}
