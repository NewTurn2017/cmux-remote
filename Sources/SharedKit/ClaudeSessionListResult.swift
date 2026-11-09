import Foundation

/// One Claude session whose transcript the relay may read. Carries no file path.
public struct ClaudeSessionSummary: Codable, Sendable, Equatable {
    /// Claude session id, used for `claude.transcript.page`.
    public var sessionId: String
    /// Session title.
    public var title: String?
    /// Session working directory.
    public var cwd: String?
    /// Git branch at the session's working directory.
    public var gitBranch: String?
    /// Session status from cmux, such as `live`, `idle`, or `exited`.
    public var status: String?
    /// Creation time in milliseconds since 1970.
    public var createdAt: Int64?
    /// Last modification time in milliseconds since 1970.
    public var modifiedAt: Int64?

    /// Creates a session summary.
    public init(sessionId: String, title: String? = nil, cwd: String? = nil, gitBranch: String? = nil,
                status: String? = nil, createdAt: Int64? = nil, modifiedAt: Int64? = nil) {
        self.sessionId = sessionId; self.title = title; self.cwd = cwd; self.gitBranch = gitBranch
        self.status = status; self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }

    /// Decodes and validates a session summary. Other keys, such as a file path, are ignored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.contractSessionId(.sessionId, field: "session_id")
        title = try c.contractOptionalText(.title, field: "title", maxCharacters: ClaudeTranscriptLimits.maxSessionTitleCharacters)
        cwd = try c.contractOptionalText(.cwd, field: "cwd", maxCharacters: ClaudeTranscriptLimits.maxCwdCharacters)
        gitBranch = try c.contractOptionalText(.gitBranch, field: "git_branch", maxCharacters: ClaudeTranscriptLimits.maxGitBranchCharacters)
        status = try c.contractOptionalText(.status, field: "status", maxCharacters: ClaudeTranscriptLimits.maxStatusCharacters)
        createdAt = try c.contractOptional(Int64.self, .createdAt, field: "created_at")
        modifiedAt = try c.contractOptional(Int64.self, .modifiedAt, field: "modified_at")
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, title, cwd, gitBranch, status, createdAt, modifiedAt
    }
}

/// Result of `claude.sessions.list`: sessions, most recently modified first.
public struct ClaudeSessionListResult: Codable, Sendable, Equatable {
    /// Sessions, most recently modified first.
    public var sessions: [ClaudeSessionSummary]

    /// Creates a session-list result.
    public init(sessions: [ClaudeSessionSummary]) {
        self.sessions = sessions
    }

    /// Decodes and validates a session-list result.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.contractRequired([ClaudeSessionSummary].self, .sessions, field: "sessions")
    }

    private enum CodingKeys: String, CodingKey {
        case sessions
    }
}
