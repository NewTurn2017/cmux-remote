import Foundation
import Testing
@testable import SharedKit

private let validSessionId = "0f2c3a10-1111-4222-8333-944455556666"

@Suite("Claude transcript protocol")
struct ClaudeTranscriptProtocolTests {
    private func keys<Value: Encodable>(_ value: Value) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: SharedKitJSON.snakeCaseEncoder.encode(value)) as? [String: Any]
        return Set(object?.keys.map { $0 } ?? [])
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try SharedKitJSON.snakeCaseDecoder.decode(type, from: Data(json.utf8))
    }

    private func quoted(_ text: String) -> String {
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }

    @Test func transcriptLimitsAreExact() {
        #expect(ClaudeTranscriptLimits.defaultSessionLimit == 50)
        #expect(ClaudeTranscriptLimits.maxSessionLimit == 100)
        #expect(ClaudeTranscriptLimits.maxSessionIdCharacters == 128)
        #expect(ClaudeTranscriptLimits.maxSessionTitleCharacters == 512)
        #expect(ClaudeTranscriptLimits.maxCwdCharacters == 1_024)
        #expect(ClaudeTranscriptLimits.maxGitBranchCharacters == 256)
        #expect(ClaudeTranscriptLimits.maxStatusCharacters == 32)
        #expect(ClaudeTranscriptLimits.defaultPageEntries == 40)
        #expect(ClaudeTranscriptLimits.maxPageEntries == 100)
        #expect(ClaudeTranscriptLimits.maxBlocksPerEntry == 32)
        #expect(ClaudeTranscriptLimits.maxTextBytes == 16_384)
        #expect(ClaudeTranscriptLimits.maxToolNameCharacters == 128)
        #expect(ClaudeTranscriptLimits.maxToolUseSummaryCharacters == 512)
        #expect(ClaudeTranscriptLimits.maxToolResultSummaryBytes == 2_048)
        #expect(ClaudeTranscriptLimits.maxLineBytes == 4_194_304)
        #expect(ClaudeTranscriptLimits.maxScanBytesPerRequest == 16_777_216)
        #expect(ClaudeTranscriptLimits.readBlockBytes == 262_144)
        #expect(ClaudeTranscriptLimits.maxResponseBytes == 737_280)
        #expect(ClaudeTranscriptLimits.responseEnvelopeReserveBytes == 8_192)
        #expect(ClaudeTranscriptRole.allCases.map(\.rawValue) == ["user", "assistant"])
        #expect(ClaudeTranscriptBlockKind.allCases.map(\.rawValue) == ["text", "toolUse", "toolResult"])
    }

    @Test(arguments: [
        (validSessionId, true), ("abc_DEF.1-2", true), (String(repeating: "a", count: 128), true),
        ("", false), (".", false), ("..", false), ("a/b", false), ("../x", false), ("a b", false),
        ("세션", false), (String(repeating: "a", count: 129), false),
    ])
    func sessionIdValidation(value: String, valid: Bool) {
        #expect(ClaudeTranscriptLimits.isValidSessionId(value) == valid)
    }

    @Test func sessionListRequestAndResultRoundTripWithoutFilePaths() throws {
        let request = ClaudeSessionListRequest(limit: 20)
        let envelope = try RPCRequest(id: "s", method: RemoteRPCMethod.claudeSessionsList.rawValue, payload: request)
        #expect(envelope.params == .object(["limit": .int(20)]))
        #expect(try keys(ClaudeSessionListRequest()).isEmpty)
        #expect(try decode(ClaudeSessionListRequest.self, "{}") == ClaudeSessionListRequest())

        let full = ClaudeSessionSummary(
            sessionId: validSessionId, title: "합성 제목", cwd: "/tmp/project", gitBranch: "main",
            status: "live", createdAt: 1_794_230_000_000, modifiedAt: 1_794_240_000_000
        )
        let bare = ClaudeSessionSummary(sessionId: "abc")
        let result = ClaudeSessionListResult(sessions: [full, bare])
        #expect(try keys(full) == ["session_id", "title", "cwd", "git_branch", "status", "created_at", "modified_at"])
        #expect(try keys(bare) == ["session_id"])
        #expect(try keys(result) == ["sessions"])

        let data = try SharedKitJSON.snakeCaseEncoder.encode(result)
        #expect(try SharedKitJSON.snakeCaseDecoder.decode(ClaudeSessionListResult.self, from: data) == result)
        #expect(try JSONDecoder().decode(ClaudeSessionListResult.self, from: JSONEncoder().encode(result)) == result)
        let response = RPCResponse(id: "s", ok: true, result: try JSONDecoder().decode(JSONValue.self, from: data))
        #expect(try response.decodeResult(ClaudeSessionListResult.self) == result)

        let withPaths = try decode(ClaudeSessionSummary.self,
            #"{"session_id":"abc","file":"/Users/x/.claude/projects/p/abc.jsonl","resume_command":"claude --resume abc"}"#)
        #expect(withPaths == bare)
        #expect(try keys(withPaths) == ["session_id"])
    }

    @Test(arguments: [
        (#"{"limit":0}"#, RemoteProtocolError.invalidField("limit")),
        (#"{"limit":101}"#, RemoteProtocolError.invalidField("limit")),
    ])
    func sessionListRequestRejectsLimitOutsideRange(json: String, expected: RemoteProtocolError) {
        #expect(throws: expected) { try decode(ClaudeSessionListRequest.self, json) }
    }

    @Test(arguments: [
        (#"{}"#, RemoteProtocolError.missingField("session_id")),
        (#"{"session_id":""}"#, RemoteProtocolError.missingField("session_id")),
        (#"{"session_id":"../etc"}"#, RemoteProtocolError.invalidField("session_id")),
        (#"{"session_id":"abc","created_at":"2026-11-09T00:00:00Z"}"#, RemoteProtocolError.invalidField("created_at")),
        (#"{"session_id":"abc","status":"\#(String(repeating: "s", count: 33))"}"#, RemoteProtocolError.invalidField("status")),
        (#"{"session_id":"abc","git_branch":"\#(String(repeating: "b", count: 257))"}"#, RemoteProtocolError.invalidField("git_branch")),
        (#"{"session_id":"abc","cwd":"\#(String(repeating: "c", count: 1025))"}"#, RemoteProtocolError.invalidField("cwd")),
        (#"{"session_id":"abc","title":"\#(String(repeating: "t", count: 513))"}"#, RemoteProtocolError.invalidField("title")),
    ])
    func sessionSummaryRejectsInvalidPayloads(json: String, expected: RemoteProtocolError) {
        #expect(throws: expected) { try decode(ClaudeSessionSummary.self, json) }
    }

    @Test func pageRequestRoundTripsAndOmitsMissingFields() throws {
        let older = ClaudeTranscriptPageRequest(sessionId: validSessionId, before: 60_666_337, maxEntries: 40)
        let envelope = try RPCRequest(id: "t", method: RemoteRPCMethod.claudeTranscriptPage.rawValue, payload: older)
        #expect(envelope.params == .object([
            "session_id": .string(validSessionId), "before": .int(60_666_337), "max_entries": .int(40),
        ]))
        #expect(try decode(ClaudeTranscriptPageRequest.self, #"{"session_id":"\#(validSessionId)","before":60666337,"max_entries":40}"#) == older)

        let latest = ClaudeTranscriptPageRequest(sessionId: validSessionId)
        #expect(try keys(latest) == ["session_id"])
        #expect(try decode(ClaudeTranscriptPageRequest.self, #"{"session_id":"\#(validSessionId)","before":0}"#).before == 0)
    }

    @Test(arguments: [
        (#"{"before":10}"#, RemoteProtocolError.missingField("session_id")),
        (#"{"session_id":"a/b"}"#, RemoteProtocolError.invalidField("session_id")),
        (#"{"session_id":"abc","before":-1}"#, RemoteProtocolError.invalidField("before")),
        (#"{"session_id":"abc","before":1.5}"#, RemoteProtocolError.invalidField("before")),
        (#"{"session_id":"abc","max_entries":0}"#, RemoteProtocolError.invalidField("max_entries")),
        (#"{"session_id":"abc","max_entries":101}"#, RemoteProtocolError.invalidField("max_entries")),
    ])
    func pageRequestRejectsInvalidPayloads(json: String, expected: RemoteProtocolError) {
        #expect(throws: expected) { try decode(ClaudeTranscriptPageRequest.self, json) }
    }

    @Test func pageResultRoundTripsEntriesAndOmitsMissingOptionals() throws {
        let user = ClaudeTranscriptEntry(
            id: "uuid-u1", role: .user, timestamp: 1_794_239_000_000,
            blocks: [ClaudeTranscriptBlock(kind: .text, text: "테스트 고쳐줘")]
        )
        let toolUse = ClaudeTranscriptEntry(
            id: "uuid-a1", role: .assistant, timestamp: 1_794_239_001_000, messageId: "msg_1",
            blocks: [ClaudeTranscriptBlock(kind: .toolUse, toolName: "Bash", summary: "swift test")]
        )
        let toolResult = ClaudeTranscriptEntry(
            id: "uuid-r1", role: .user,
            blocks: [ClaudeTranscriptBlock(kind: .toolResult, summary: "passed", isError: false, truncated: true)]
        )
        let page = ClaudeTranscriptPageResult(sessionId: validSessionId, entries: [user, toolUse, toolResult],
                                              before: 60_666_337, fileSize: 61_555_761)

        #expect(try keys(page) == ["session_id", "entries", "before", "file_size"])
        #expect(try keys(user) == ["id", "role", "timestamp", "blocks"])
        #expect(try keys(toolUse) == ["id", "role", "timestamp", "message_id", "blocks"])
        #expect(try keys(user.blocks[0]) == ["kind", "text"])
        #expect(try keys(toolUse.blocks[0]) == ["kind", "tool_name", "summary"])
        #expect(try keys(toolResult.blocks[0]) == ["kind", "summary", "is_error", "truncated"])

        let data = try SharedKitJSON.snakeCaseEncoder.encode(page)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = object?["entries"] as? [[String: Any]]
        let firstBlock = (entries?[1]["blocks"] as? [[String: Any]])?.first
        #expect(firstBlock?["kind"] as? String == "toolUse")
        #expect(try SharedKitJSON.snakeCaseDecoder.decode(ClaudeTranscriptPageResult.self, from: data) == page)
        #expect(try JSONDecoder().decode(ClaudeTranscriptPageResult.self, from: JSONEncoder().encode(page)) == page)
        let response = RPCResponse(id: "t", ok: true, result: try JSONDecoder().decode(JSONValue.self, from: data))
        #expect(try response.decodeResult(ClaudeTranscriptPageResult.self) == page)

        let start = ClaudeTranscriptPageResult(sessionId: validSessionId, entries: [], fileSize: 0)
        #expect(try keys(start) == ["session_id", "entries", "file_size"])
        #expect(try decode(ClaudeTranscriptPageResult.self, #"{"session_id":"abc","entries":[],"file_size":10,"before":10}"#).before == 10)
    }

    private static let textBlock = #"{"kind":"text","text":"t"}"#

    @Test(arguments: [
        (#"{"entries":[],"file_size":1}"#, RemoteProtocolError.missingField("session_id")),
        (#"{"session_id":"abc","file_size":1}"#, RemoteProtocolError.missingField("entries")),
        (#"{"session_id":"abc","entries":[]}"#, RemoteProtocolError.missingField("file_size")),
        (#"{"session_id":"abc","entries":[],"file_size":-1}"#, RemoteProtocolError.invalidField("file_size")),
        (#"{"session_id":"abc","entries":[],"file_size":10,"before":11}"#, RemoteProtocolError.invalidField("before")),
        (#"{"session_id":"abc","entries":[],"file_size":10,"before":0}"#, RemoteProtocolError.invalidField("before")),
        (#"{"session_id":"abc","entries":[{"id":"u","role":"system","blocks":[{"kind":"text","text":"t"}]}],"file_size":1}"#, RemoteProtocolError.invalidField("role")),
        (#"{"session_id":"abc","entries":[{"id":"u","blocks":[{"kind":"text","text":"t"}]}],"file_size":1}"#, RemoteProtocolError.missingField("role")),
        (#"{"session_id":"abc","entries":[{"id":"","role":"user","blocks":[{"kind":"text","text":"t"}]}],"file_size":1}"#, RemoteProtocolError.missingField("id")),
        (#"{"session_id":"abc","entries":[{"id":"u","role":"user","blocks":[]}],"file_size":1}"#, RemoteProtocolError.invalidField("blocks")),
        (#"{"session_id":"abc","entries":[{"id":"u","role":"user","timestamp":"2026-11-09T00:00:00Z","blocks":[{"kind":"text","text":"t"}]}],"file_size":1}"#, RemoteProtocolError.invalidField("timestamp")),
        (#"{"session_id":"abc","entries":[{"id":"u","role":"assistant","blocks":[{"kind":"thinking","text":"t"}]}],"file_size":1}"#, RemoteProtocolError.invalidField("kind")),
    ])
    func pageResultRejectsInvalidPayloads(json: String, expected: RemoteProtocolError) {
        #expect(throws: expected) { try decode(ClaudeTranscriptPageResult.self, json) }
    }

    @Test(arguments: [
        (#"{"kind":"image"}"#, RemoteProtocolError.invalidField("kind")),
        (#"{"text":"t"}"#, RemoteProtocolError.missingField("kind")),
        (#"{"kind":"text"}"#, RemoteProtocolError.missingField("text")),
        (#"{"kind":"text","text":""}"#, RemoteProtocolError.missingField("text")),
        (#"{"kind":"toolUse","summary":"ls"}"#, RemoteProtocolError.missingField("tool_name")),
        (#"{"kind":"toolResult","is_error":"yes"}"#, RemoteProtocolError.invalidField("is_error")),
    ])
    func blockRejectsUnknownKindsAndMissingKindFields(json: String, expected: RemoteProtocolError) {
        #expect(throws: expected) { try decode(ClaudeTranscriptBlock.self, json) }
    }

    @Test func blockAndEntryEnforceLimitsAtTheBoundary() throws {
        let text = String(repeating: "x", count: ClaudeTranscriptLimits.maxTextBytes)
        #expect((try? decode(ClaudeTranscriptBlock.self, #"{"kind":"text","text":\#(quoted(text))}"#)) != nil)
        #expect(throws: RemoteProtocolError.invalidField("text")) {
            try decode(ClaudeTranscriptBlock.self, #"{"kind":"text","text":\#(quoted(text + "x"))}"#)
        }
        let koreanText = String(repeating: "한", count: ClaudeTranscriptLimits.maxTextBytes / 3 + 1)
        #expect(throws: RemoteProtocolError.invalidField("text")) {
            try decode(ClaudeTranscriptBlock.self, #"{"kind":"text","text":\#(quoted(koreanText))}"#)
        }

        let useSummary = String(repeating: "한", count: ClaudeTranscriptLimits.maxToolUseSummaryCharacters)
        #expect((try? decode(ClaudeTranscriptBlock.self, #"{"kind":"toolUse","tool_name":"Bash","summary":\#(quoted(useSummary))}"#)) != nil)
        #expect(throws: RemoteProtocolError.invalidField("summary")) {
            try decode(ClaudeTranscriptBlock.self, #"{"kind":"toolUse","tool_name":"Bash","summary":\#(quoted(useSummary + "한"))}"#)
        }

        let resultSummary = String(repeating: "x", count: ClaudeTranscriptLimits.maxToolResultSummaryBytes)
        #expect((try? decode(ClaudeTranscriptBlock.self, #"{"kind":"toolResult","summary":\#(quoted(resultSummary))}"#)) != nil)
        #expect(throws: RemoteProtocolError.invalidField("summary")) {
            try decode(ClaudeTranscriptBlock.self, #"{"kind":"toolResult","summary":\#(quoted(resultSummary + "x"))}"#)
        }

        let toolName = String(repeating: "T", count: ClaudeTranscriptLimits.maxToolNameCharacters + 1)
        #expect(throws: RemoteProtocolError.invalidField("tool_name")) {
            try decode(ClaudeTranscriptBlock.self, #"{"kind":"toolUse","tool_name":\#(quoted(toolName))}"#)
        }

        let maxBlocks = Array(repeating: Self.textBlock, count: ClaudeTranscriptLimits.maxBlocksPerEntry).joined(separator: ",")
        #expect((try? decode(ClaudeTranscriptEntry.self, #"{"id":"u","role":"user","blocks":[\#(maxBlocks)]}"#)) != nil)
        #expect(throws: RemoteProtocolError.invalidField("blocks")) {
            try decode(ClaudeTranscriptEntry.self, #"{"id":"u","role":"user","blocks":[\#(maxBlocks),\#(Self.textBlock)]}"#)
        }

        let entry = #"{"id":"u","role":"user","blocks":[\#(Self.textBlock)]}"#
        let maxEntries = Array(repeating: entry, count: ClaudeTranscriptLimits.maxPageEntries).joined(separator: ",")
        #expect((try? decode(ClaudeTranscriptPageResult.self, #"{"session_id":"abc","entries":[\#(maxEntries)],"file_size":1}"#)) != nil)
        #expect(throws: RemoteProtocolError.invalidField("entries")) {
            try decode(ClaudeTranscriptPageResult.self, #"{"session_id":"abc","entries":[\#(maxEntries),\#(entry)],"file_size":1}"#)
        }
    }
}
