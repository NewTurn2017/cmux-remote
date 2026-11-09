import Foundation
import SharedKit
@testable import CmuxRemote

enum TranscriptFixtures {
    static let list = RemoteRPCMethod.claudeSessionsList.rawValue
    static let page = RemoteRPCMethod.claudeTranscriptPage.rawValue
    static let sessionID = "session-1"
    static let fileSize: Int64 = 1_000_000

    static func session(_ id: String = sessionID, status: String? = "idle", modifiedAt: Int64? = 1_000) -> ClaudeSessionSummary {
        ClaudeSessionSummary(sessionId: id, title: "Title \(id)", cwd: "/tmp/project", gitBranch: "main", status: status, modifiedAt: modifiedAt)
    }

    static func user(_ id: String, text: String = "question") -> ClaudeTranscriptEntry {
        ClaudeTranscriptEntry(id: id, role: .user, blocks: [ClaudeTranscriptBlock(kind: .text, text: text)])
    }

    static func assistant(_ id: String, messageId: String? = nil, text: String = "answer") -> ClaudeTranscriptEntry {
        ClaudeTranscriptEntry(id: id, role: .assistant, messageId: messageId, blocks: [ClaudeTranscriptBlock(kind: .text, text: text)])
    }

    static func toolUse(_ id: String, messageId: String? = nil) -> ClaudeTranscriptEntry {
        ClaudeTranscriptEntry(id: id, role: .assistant, messageId: messageId, blocks: [
            ClaudeTranscriptBlock(kind: .toolUse, toolName: "Bash", summary: "make test"),
        ])
    }

    static func rows(_ entries: [ClaudeTranscriptEntry]) -> [ClaudeTranscriptRow] {
        entries.map(ClaudeTranscriptRow.init(entry:))
    }

    static func users(_ ids: [String]) -> [ClaudeTranscriptEntry] {
        ids.map { user($0) }
    }

    static func sessionsResponse(_ sessions: [ClaudeSessionSummary]) throws -> RPCResponse {
        try encoded(ClaudeSessionListResult(sessions: sessions))
    }

    static func pageResponse(_ entries: [ClaudeTranscriptEntry], before: Int64?, sessionID: String = sessionID) throws -> RPCResponse {
        try encoded(ClaudeTranscriptPageResult(sessionId: sessionID, entries: entries, before: before, fileSize: fileSize))
    }

    static func error(_ code: String, field: String? = nil) -> RPCResponse {
        RPCResponse(id: "error", ok: false, error: RPCError(
            code: code,
            message: code,
            data: field.map { .object(["field": .string($0)]) }
        ))
    }

    static func requests(_ params: [JSONValue]) throws -> [ClaudeTranscriptPageRequest] {
        try params.map { try $0.decode(ClaudeTranscriptPageRequest.self) }
    }

    private static func encoded<Value: Encodable>(_ value: Value) throws -> RPCResponse {
        let data = try SharedKitJSON.snakeCaseEncoder.encode(value)
        return RPCResponse(id: "transcript", ok: true, result: try JSONDecoder().decode(JSONValue.self, from: data))
    }
}
