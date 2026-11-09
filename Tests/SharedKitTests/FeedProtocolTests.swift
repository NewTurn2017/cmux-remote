import Foundation
import Testing
@testable import SharedKit

private let pendingItemCommonFields = #""id":"i","request_id":"r","source":"claude","workstream_id":"w""#

@Suite("Feed protocol")
struct FeedProtocolTests {
    private func keys<Value: Encodable>(_ value: Value) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: SharedKitJSON.snakeCaseEncoder.encode(value)) as? [String: Any]
        return Set(object?.keys.map { $0 } ?? [])
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try SharedKitJSON.snakeCaseDecoder.decode(type, from: Data(json.utf8))
    }

    @Test func newIdentifiersHaveExactWireValues() throws {
        let methods: [(RemoteRPCMethod, String)] = [
            (.feedPendingList, "feed.pending.list"),
            (.feedReply, "feed.reply"),
            (.claudeSessionsList, "claude.sessions.list"),
            (.claudeTranscriptPage, "claude.transcript.page"),
        ]
        for (method, raw) in methods {
            #expect(method.rawValue == raw)
            #expect(RemoteRPCMethod(rawValue: raw) == method)
        }

        #expect(HostCapabilities.feedV1 == "feed.v1")
        #expect(HostCapabilities.claudeTranscriptV1 == "claude.transcript.v1")
        #expect(HostCapabilitiesResult.feedV1Capability == "feed.v1")
        #expect(HostCapabilitiesResult.claudeTranscriptV1Capability == "claude.transcript.v1")
        #expect(HostCapabilitiesResult(capabilities: ["feed.v1"]).supportsFeedV1)
        #expect(!HostCapabilitiesResult(capabilities: ["feed.v1"]).supportsClaudeTranscriptV1)
        #expect(HostCapabilitiesResult(capabilities: ["claude.transcript.v1"]).supportsClaudeTranscriptV1)
        #expect(!HostCapabilitiesResult(capabilities: ["surface.browser.v1"]).supportsFeedV1)

        let codes: [(RemoteErrorCode, String)] = [
            (.feedRequestNotPending, "feed_request_not_pending"),
            (.claudeSessionNotFound, "claude_session_not_found"),
        ]
        for (code, raw) in codes {
            #expect(code.rawValue == raw)
            #expect(RemoteErrorCode(rawValue: raw) == code)
            let encoded = try JSONEncoder().encode(code)
            #expect(String(decoding: encoded, as: UTF8.self) == "\"\(raw)\"")
            #expect(try JSONDecoder().decode(RemoteErrorCode.self, from: encoded) == code)
        }
    }

    @Test func feedLimitsAreExact() {
        #expect(FeedLimits.defaultListLimit == 50)
        #expect(FeedLimits.maxListLimit == 100)
        #expect(FeedLimits.maxRequestIdCharacters == 256)
        #expect(FeedLimits.maxTitleCharacters == 512)
        #expect(FeedLimits.maxCwdCharacters == 1_024)
        #expect(FeedLimits.maxToolNameCharacters == 128)
        #expect(FeedLimits.maxToolInputBytes == 16_384)
        #expect(FeedLimits.maxPlanTextBytes == 65_536)
        #expect(FeedLimits.maxQuestions == 10)
        #expect(FeedLimits.maxQuestionPromptBytes == 2_048)
        #expect(FeedLimits.maxOptionsPerQuestion == 32)
        #expect(FeedLimits.maxOptionLabelCharacters == 512)
        #expect(FeedLimits.maxSelections == 50)
        #expect(FeedLimits.permissionModes == ["once", "always", "deny"])
        #expect(FeedLimits.planModes == ["autoAccept", "manual", "deny"])
        #expect(FeedLimits.maxResponseBytes == 737_280)
        #expect(FeedLimits.responseEnvelopeReserveBytes == 8_192)
        #expect(FeedItemKind.allCases.map(\.rawValue) == ["question", "permission", "plan"])
        #expect(FeedItemKind.question.replyModes.isEmpty)
    }

    @Test func pendingListRequestRoundTripsAndOmitsMissingLimit() throws {
        let request = FeedPendingListRequest(limit: 50)
        let envelope = try RPCRequest(id: "f", method: RemoteRPCMethod.feedPendingList.rawValue, payload: request)
        #expect(envelope.params == .object(["limit": .int(50)]))
        #expect(try decode(FeedPendingListRequest.self, #"{"limit":50}"#) == request)

        let bare = FeedPendingListRequest()
        #expect(try keys(bare).isEmpty)
        #expect(try decode(FeedPendingListRequest.self, "{}") == bare)
    }

    @Test(arguments: [#"{"limit":0}"#, #"{"limit":101}"#, #"{"limit":"50"}"#])
    func pendingListRequestRejectsLimitOutsideRange(json: String) {
        #expect(throws: RemoteProtocolError.invalidField("limit")) {
            try decode(FeedPendingListRequest.self, json)
        }
    }

    @Test func pendingListResultRoundTripsEveryKindWithSnakeCaseKeys() throws {
        let question = FeedPendingItem(
            id: "item-q", requestId: "req-q", kind: .question, source: "claude", workstreamId: "ws-1",
            createdAt: 1_794_240_000_000, title: "Question", cwd: "/tmp/project",
            questions: [
                FeedQuestion(id: "q1", prompt: "Pick one", multiSelect: false,
                             options: [FeedOption(id: "o1", label: "A"), FeedOption(id: "o2", label: "B")]),
                FeedQuestion(id: "q2", prompt: "No options", multiSelect: false, options: []),
            ]
        )
        let permission = FeedPendingItem(
            id: "item-p", requestId: "req-p", kind: .permission, source: "claude", workstreamId: "ws-1",
            toolName: "Bash", toolInput: #"{"command":"npm test"}"#, toolInputTruncated: true,
            availableModes: ["once", "always", "deny"]
        )
        let plan = FeedPendingItem(
            id: "item-x", requestId: "req-x", kind: .plan, source: "codex", workstreamId: "ws-2",
            availableModes: ["autoAccept", "manual", "deny"], defaultMode: "manual",
            planText: "1. read\n2. edit", planTextTruncated: false
        )
        let result = FeedPendingListResult(items: [question, permission, plan], truncated: true, omittedCount: 3)

        #expect(try keys(result) == ["items", "truncated", "omitted_count"])
        #expect(try keys(question) == ["id", "request_id", "kind", "source", "workstream_id", "created_at", "title", "cwd", "questions"])
        #expect(try keys(permission) == ["id", "request_id", "kind", "source", "workstream_id", "tool_name", "tool_input", "tool_input_truncated", "available_modes"])
        #expect(try keys(plan) == ["id", "request_id", "kind", "source", "workstream_id", "available_modes", "default_mode", "plan_text", "plan_text_truncated"])
        #expect(try keys(question.questions![0]) == ["id", "prompt", "multi_select", "options"])

        let data = try SharedKitJSON.snakeCaseEncoder.encode(result)
        #expect(try SharedKitJSON.snakeCaseDecoder.decode(FeedPendingListResult.self, from: data) == result)
        #expect(try JSONDecoder().decode(FeedPendingListResult.self, from: JSONEncoder().encode(result)) == result)
        let response = RPCResponse(id: "f", ok: true, result: try JSONDecoder().decode(JSONValue.self, from: data))
        #expect(try response.decodeResult(FeedPendingListResult.self) == result)

        let empty = FeedPendingListResult(items: [], truncated: false)
        #expect(try keys(empty) == ["items", "truncated"])
        #expect(try decode(FeedPendingListResult.self, #"{"items":[],"truncated":false}"#) == empty)
    }

    @Test(arguments: [
        (#"{"items":[]}"#, RemoteProtocolError.missingField("truncated")),
        (#"{"truncated":false}"#, RemoteProtocolError.missingField("items")),
        (#"{"items":[],"truncated":false,"omitted_count":-1}"#, RemoteProtocolError.invalidField("omitted_count")),
        (#"{"items":[{\#(pendingItemCommonFields),"kind":"telemetry"}],"truncated":false}"#, RemoteProtocolError.invalidField("kind")),
        (#"{"items":[{\#(pendingItemCommonFields),"kind":"permissionRequest"}],"truncated":false}"#, RemoteProtocolError.invalidField("kind")),
        (#"{"items":[{"id":"i","source":"claude","workstream_id":"w","kind":"plan"}],"truncated":false}"#, RemoteProtocolError.missingField("request_id")),
        (#"{"items":[{"id":"i","request_id":"","source":"claude","workstream_id":"w","kind":"plan"}],"truncated":false}"#, RemoteProtocolError.missingField("request_id")),
        (#"{"items":[{\#(pendingItemCommonFields),"kind":"plan","created_at":"2026-11-09T00:00:00Z"}],"truncated":false}"#, RemoteProtocolError.invalidField("created_at")),
        (#"{"items":[{\#(pendingItemCommonFields),"kind":"permission","available_modes":["once","bypass"]}],"truncated":false}"#, RemoteProtocolError.invalidField("available_modes")),
        (#"{"items":[{\#(pendingItemCommonFields),"kind":"permission","available_modes":["all"]}],"truncated":false}"#, RemoteProtocolError.invalidField("available_modes")),
        (#"{"items":[{\#(pendingItemCommonFields),"kind":"plan","available_modes":["once"]}],"truncated":false}"#, RemoteProtocolError.invalidField("available_modes")),
        (#"{"items":[{\#(pendingItemCommonFields),"kind":"plan","default_mode":"bypassPermissions"}],"truncated":false}"#, RemoteProtocolError.invalidField("default_mode")),
        (#"{"items":[{\#(pendingItemCommonFields),"kind":"plan","default_mode":"ultraplan"}],"truncated":false}"#, RemoteProtocolError.invalidField("default_mode")),
        (#"{"items":[{\#(pendingItemCommonFields),"kind":"question","questions":[{"id":"q","prompt":"p","options":[]}]}],"truncated":false}"#, RemoteProtocolError.missingField("multi_select")),
        (#"{"items":[{\#(pendingItemCommonFields),"kind":"question","questions":[{"id":"q","prompt":"","multi_select":false,"options":[]}]}],"truncated":false}"#, RemoteProtocolError.missingField("prompt")),
        (#"{"items":[{\#(pendingItemCommonFields),"kind":"question","questions":[{"id":"q","prompt":"p","multi_select":false,"options":[{"id":"o","label":""}]}]}],"truncated":false}"#, RemoteProtocolError.missingField("label")),
    ])
    func pendingListResultRejectsInvalidPayloads(json: String, expected: RemoteProtocolError) {
        #expect(throws: expected) { try decode(FeedPendingListResult.self, json) }
    }

    @Test func pendingItemEnforcesStringLimitsAtTheBoundary() throws {
        func item(_ extra: String, kind: String = "permission") -> String {
            #"{"id":"i","request_id":"r","kind":"\#(kind)","source":"claude","workstream_id":"w",\#(extra)}"#
        }
        func quoted(_ text: String) -> String {
            String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        }
        let cases: [(field: String, wire: String, limit: Int, unit: String, kind: String)] = [
            ("title", "title", FeedLimits.maxTitleCharacters, "한", "permission"),
            ("cwd", "cwd", FeedLimits.maxCwdCharacters, "x", "permission"),
            ("tool_name", "tool_name", FeedLimits.maxToolNameCharacters, "x", "permission"),
            ("tool_input", "tool_input", FeedLimits.maxToolInputBytes, "x", "permission"),
            ("plan_text", "plan_text", FeedLimits.maxPlanTextBytes, "x", "plan"),
        ]
        for c in cases {
            let atLimit = String(repeating: c.unit, count: c.limit)
            #expect((try? decode(FeedPendingItem.self, item("\"\(c.wire)\":\(quoted(atLimit))", kind: c.kind))) != nil)
            #expect(throws: RemoteProtocolError.invalidField(c.field)) {
                try decode(FeedPendingItem.self, item("\"\(c.wire)\":\(quoted(atLimit + c.unit))", kind: c.kind))
            }
        }

        let multiByteInput = String(repeating: "한", count: FeedLimits.maxToolInputBytes / 3 + 1)
        #expect(throws: RemoteProtocolError.invalidField("tool_input")) {
            try decode(FeedPendingItem.self, item("\"tool_input\":\(quoted(multiByteInput))"))
        }

        let longPrompt = String(repeating: "x", count: FeedLimits.maxQuestionPromptBytes + 1)
        #expect(throws: RemoteProtocolError.invalidField("prompt")) {
            try decode(FeedQuestion.self, #"{"id":"q","prompt":\#(quoted(longPrompt)),"multi_select":false,"options":[]}"#)
        }
        let longLabel = String(repeating: "x", count: FeedLimits.maxOptionLabelCharacters + 1)
        #expect(throws: RemoteProtocolError.invalidField("label")) {
            try decode(FeedOption.self, #"{"id":"o","label":\#(quoted(longLabel))}"#)
        }

        let option = #"{"id":"o","label":"l"}"#
        let maxOptions = Array(repeating: option, count: FeedLimits.maxOptionsPerQuestion).joined(separator: ",")
        #expect((try? decode(FeedQuestion.self, #"{"id":"q","prompt":"p","multi_select":true,"options":[\#(maxOptions)]}"#)) != nil)
        #expect(throws: RemoteProtocolError.invalidField("options")) {
            try decode(FeedQuestion.self, #"{"id":"q","prompt":"p","multi_select":true,"options":[\#(maxOptions),\#(option)]}"#)
        }

        let question = #"{"id":"q","prompt":"p","multi_select":false,"options":[]}"#
        let maxQuestions = Array(repeating: question, count: FeedLimits.maxQuestions).joined(separator: ",")
        #expect((try? decode(FeedPendingItem.self, item(#""questions":[\#(maxQuestions)]"#, kind: "question"))) != nil)
        #expect(throws: RemoteProtocolError.invalidField("questions")) {
            try decode(FeedPendingItem.self, item(#""questions":[\#(maxQuestions),\#(question)]"#, kind: "question"))
        }
    }

    @Test func replyRequestRoundTripsEachKindWithOnlyItsFields() throws {
        let question = FeedReplyRequest(requestId: "req-q", kind: .question, selections: ["A", "B"])
        let permission = FeedReplyRequest(requestId: "req-p", kind: .permission, mode: "once")
        let plan = FeedReplyRequest(requestId: "req-x", kind: .plan, mode: "autoAccept")

        let envelope = try RPCRequest(id: "r", method: RemoteRPCMethod.feedReply.rawValue, payload: question)
        #expect(envelope.params == .object([
            "request_id": .string("req-q"), "kind": .string("question"),
            "selections": .array([.string("A"), .string("B")]),
        ]))
        #expect(try keys(permission) == ["request_id", "kind", "mode"])
        #expect(try keys(plan) == ["request_id", "kind", "mode"])
        for request in [question, permission, plan] {
            let data = try SharedKitJSON.snakeCaseEncoder.encode(request)
            #expect(try SharedKitJSON.snakeCaseDecoder.decode(FeedReplyRequest.self, from: data) == request)
        }

        let emptyAnswer = try decode(FeedReplyRequest.self, #"{"request_id":"r","kind":"question","selections":[]}"#)
        #expect(emptyAnswer.selections == [])

        let withFeedback = try decode(FeedReplyRequest.self, #"{"request_id":"r","kind":"plan","mode":"deny","feedback":"x"}"#)
        #expect(try keys(withFeedback) == ["request_id", "kind", "mode"])

        let result = FeedReplyResult(requestId: "req-q", kind: .question)
        #expect(try keys(result) == ["request_id", "kind"])
        let resultData = try SharedKitJSON.snakeCaseEncoder.encode(result)
        let response = RPCResponse(id: "r", ok: true, result: try JSONDecoder().decode(JSONValue.self, from: resultData))
        #expect(try response.decodeResult(FeedReplyResult.self) == result)
    }

    @Test(arguments: [
        (#"{"kind":"permission","mode":"once"}"#, RemoteProtocolError.missingField("request_id")),
        (#"{"request_id":"","kind":"permission","mode":"once"}"#, RemoteProtocolError.missingField("request_id")),
        (#"{"request_id":"r","mode":"once"}"#, RemoteProtocolError.missingField("kind")),
        (#"{"request_id":"r","kind":"permissionRequest","mode":"once"}"#, RemoteProtocolError.invalidField("kind")),
        (#"{"request_id":"r","kind":"permission"}"#, RemoteProtocolError.missingField("mode")),
        (#"{"request_id":"r","kind":"permission","mode":"bypass"}"#, RemoteProtocolError.invalidField("mode")),
        (#"{"request_id":"r","kind":"permission","mode":"all"}"#, RemoteProtocolError.invalidField("mode")),
        (#"{"request_id":"r","kind":"permission","mode":"autoAccept"}"#, RemoteProtocolError.invalidField("mode")),
        (#"{"request_id":"r","kind":"plan","mode":"bypassPermissions"}"#, RemoteProtocolError.invalidField("mode")),
        (#"{"request_id":"r","kind":"plan","mode":"ultraplan"}"#, RemoteProtocolError.invalidField("mode")),
        (#"{"request_id":"r","kind":"plan","mode":"once"}"#, RemoteProtocolError.invalidField("mode")),
        (#"{"request_id":"r","kind":"permission","mode":"once","selections":["A"]}"#, RemoteProtocolError.invalidField("selections")),
        (#"{"request_id":"r","kind":"question"}"#, RemoteProtocolError.missingField("selections")),
        (#"{"request_id":"r","kind":"question","mode":"once","selections":["A"]}"#, RemoteProtocolError.invalidField("mode")),
        (#"{"request_id":"r","kind":"question","selections":[""]}"#, RemoteProtocolError.invalidField("selections")),
        (#"{"request_id":"r","kind":"question","selections":"A"}"#, RemoteProtocolError.invalidField("selections")),
    ])
    func replyRequestRejectsInvalidShapes(json: String, expected: RemoteProtocolError) {
        #expect(throws: expected) { try decode(FeedReplyRequest.self, json) }
    }

    @Test func replyRequestEnforcesSelectionAndRequestIdLimits() throws {
        func question(_ selections: [String], requestId: String = "r") throws -> FeedReplyRequest {
            let payload: [String: Any] = ["request_id": requestId, "kind": "question", "selections": selections]
            return try SharedKitJSON.snakeCaseDecoder.decode(FeedReplyRequest.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let label = String(repeating: "x", count: FeedLimits.maxOptionLabelCharacters)
        #expect((try? question([label])) != nil)
        #expect(throws: RemoteProtocolError.invalidField("selections")) { try question([label + "x"]) }
        #expect((try? question(Array(repeating: "A", count: FeedLimits.maxSelections))) != nil)
        #expect(throws: RemoteProtocolError.invalidField("selections")) {
            try question(Array(repeating: "A", count: FeedLimits.maxSelections + 1))
        }
        let longId = String(repeating: "r", count: FeedLimits.maxRequestIdCharacters)
        #expect((try? question(["A"], requestId: longId)) != nil)
        #expect(throws: RemoteProtocolError.invalidField("request_id")) { try question(["A"], requestId: longId + "r") }
    }
}
