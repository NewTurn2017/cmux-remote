import Foundation

/// Parameters for `claude.transcript.page`.
public struct ClaudeTranscriptPageRequest: Codable, Sendable, Equatable {
    /// Session id from `claude.sessions.list`.
    public var sessionId: String
    /// Exclusive end byte offset from the previous page; omitted for the newest page.
    public var before: Int64?
    /// Most entries to return; the relay uses ``ClaudeTranscriptLimits/defaultPageEntries`` when omitted.
    public var maxEntries: Int?

    /// Creates a transcript-page request.
    public init(sessionId: String, before: Int64? = nil, maxEntries: Int? = nil) {
        self.sessionId = sessionId; self.before = before; self.maxEntries = maxEntries
    }

    /// Decodes and validates a transcript-page request. The relay also rejects `before` past the file end.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.contractSessionId(.sessionId, field: "session_id")
        before = try c.contractOptional(Int64.self, .before, field: "before")
        if let before, before < 0 { throw RemoteProtocolError.invalidField("before") }
        maxEntries = try c.contractOptionalInt(.maxEntries, field: "max_entries", in: 1...ClaudeTranscriptLimits.maxPageEntries)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, before, maxEntries
    }
}
