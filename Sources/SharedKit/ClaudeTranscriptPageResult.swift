import Foundation

/// Who wrote a transcript entry.
public enum ClaudeTranscriptRole: String, Codable, Sendable, Equatable, CaseIterable {
    /// The person, or a tool result returned to Claude.
    case user
    /// Claude.
    case assistant

    /// Decodes a known role and rejects unknown values with `invalid_field`.
    public init(from decoder: Decoder) throws {
        guard let raw = try? decoder.singleValueContainer().decode(String.self),
              let role = ClaudeTranscriptRole(rawValue: raw)
        else { throw RemoteProtocolError.invalidField("role") }
        self = role
    }
}

/// The kind of a displayed transcript block.
public enum ClaudeTranscriptBlockKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// Message text.
    case text
    /// A tool call: name plus a short input summary.
    case toolUse
    /// A tool result: the start of its output.
    case toolResult

    /// Decodes a known block kind and rejects unknown values with `invalid_field`.
    public init(from decoder: Decoder) throws {
        guard let raw = try? decoder.singleValueContainer().decode(String.self),
              let kind = ClaudeTranscriptBlockKind(rawValue: raw)
        else { throw RemoteProtocolError.invalidField("kind") }
        self = kind
    }
}

/// One displayed block of a transcript entry.
public struct ClaudeTranscriptBlock: Codable, Sendable, Equatable {
    /// Text, tool call, or tool result.
    public var kind: ClaudeTranscriptBlockKind
    /// Text: the message text.
    public var text: String?
    /// Tool call: the tool name.
    public var toolName: String?
    /// Tool call: input summary. Tool result: start of the output.
    public var summary: String?
    /// Tool result: whether the tool reported an error.
    public var isError: Bool?
    /// Whether ``text`` or ``summary`` was cut at its limit.
    public var truncated: Bool?

    /// Creates a transcript block.
    public init(kind: ClaudeTranscriptBlockKind, text: String? = nil, toolName: String? = nil,
                summary: String? = nil, isError: Bool? = nil, truncated: Bool? = nil) {
        self.kind = kind; self.text = text; self.toolName = toolName
        self.summary = summary; self.isError = isError; self.truncated = truncated
    }

    /// Decodes and validates a transcript block; required fields depend on ``kind``.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.contractRequired(ClaudeTranscriptBlockKind.self, .kind, field: "kind")
        text = try c.contractOptionalText(.text, field: "text", maxUTF8Bytes: ClaudeTranscriptLimits.maxTextBytes)
        toolName = try c.contractOptionalText(.toolName, field: "tool_name", maxCharacters: ClaudeTranscriptLimits.maxToolNameCharacters)
        switch kind {
        case .toolResult:
            summary = try c.contractOptionalText(.summary, field: "summary", maxUTF8Bytes: ClaudeTranscriptLimits.maxToolResultSummaryBytes)
        case .text, .toolUse:
            summary = try c.contractOptionalText(.summary, field: "summary", maxCharacters: ClaudeTranscriptLimits.maxToolUseSummaryCharacters)
        }
        isError = try c.contractOptional(Bool.self, .isError, field: "is_error")
        truncated = try c.contractOptional(Bool.self, .truncated, field: "truncated")
        switch kind {
        case .text:
            guard let text, !text.isEmpty else { throw RemoteProtocolError.missingField("text") }
        case .toolUse:
            guard let toolName, !toolName.isEmpty else { throw RemoteProtocolError.missingField("tool_name") }
        case .toolResult:
            break
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, text, toolName, summary, isError, truncated
    }
}

/// One displayed message of a Claude transcript.
public struct ClaudeTranscriptEntry: Codable, Sendable, Equatable {
    /// The transcript line's `uuid`; for merged lines, the earliest line's.
    public var id: String
    /// User or assistant.
    public var role: ClaudeTranscriptRole
    /// Line time in milliseconds since 1970.
    public var timestamp: Int64?
    /// Assistant message id. Neighboring assistant entries with the same id belong to one message.
    public var messageId: String?
    /// Displayed blocks in message order.
    public var blocks: [ClaudeTranscriptBlock]

    /// Creates a transcript entry.
    public init(id: String, role: ClaudeTranscriptRole, timestamp: Int64? = nil,
                messageId: String? = nil, blocks: [ClaudeTranscriptBlock]) {
        self.id = id; self.role = role; self.timestamp = timestamp; self.messageId = messageId; self.blocks = blocks
    }

    /// Decodes and validates a transcript entry.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.contractText(.id, field: "id")
        role = try c.contractRequired(ClaudeTranscriptRole.self, .role, field: "role")
        timestamp = try c.contractOptional(Int64.self, .timestamp, field: "timestamp")
        messageId = try c.contractOptionalText(.messageId, field: "message_id")
        blocks = try c.contractRequired([ClaudeTranscriptBlock].self, .blocks, field: "blocks")
        guard !blocks.isEmpty, blocks.count <= ClaudeTranscriptLimits.maxBlocksPerEntry else {
            throw RemoteProtocolError.invalidField("blocks")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, timestamp, messageId, blocks
    }
}

/// Result of `claude.transcript.page`: one page of entries, oldest to newest.
public struct ClaudeTranscriptPageResult: Codable, Sendable, Equatable {
    /// The requested session id.
    public var sessionId: String
    /// Entries, oldest to newest.
    public var entries: [ClaudeTranscriptEntry]
    /// Exclusive end byte offset for the next older page; omitted when the file start was reached.
    public var before: Int64?
    /// Transcript file size in bytes when the page was read.
    public var fileSize: Int64

    /// Creates a transcript page.
    public init(sessionId: String, entries: [ClaudeTranscriptEntry], before: Int64? = nil, fileSize: Int64) {
        self.sessionId = sessionId; self.entries = entries; self.before = before; self.fileSize = fileSize
    }

    /// Decodes and validates a transcript page.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.contractSessionId(.sessionId, field: "session_id")
        entries = try c.contractRequired([ClaudeTranscriptEntry].self, .entries, field: "entries")
        guard entries.count <= ClaudeTranscriptLimits.maxPageEntries else { throw RemoteProtocolError.invalidField("entries") }
        fileSize = try c.contractRequired(Int64.self, .fileSize, field: "file_size")
        guard fileSize >= 0 else { throw RemoteProtocolError.invalidField("file_size") }
        before = try c.contractOptional(Int64.self, .before, field: "before")
        if let before, !(1...fileSize).contains(before) { throw RemoteProtocolError.invalidField("before") }
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, entries, before, fileSize
    }
}
