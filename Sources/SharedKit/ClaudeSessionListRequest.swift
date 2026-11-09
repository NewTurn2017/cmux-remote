import Foundation

/// Parameters for `claude.sessions.list`.
public struct ClaudeSessionListRequest: Codable, Sendable, Equatable {
    /// Most sessions to return; the relay uses ``ClaudeTranscriptLimits/defaultSessionLimit`` when omitted.
    public var limit: Int?

    /// Creates a session-list request.
    public init(limit: Int? = nil) {
        self.limit = limit
    }

    /// Decodes and validates a session-list request.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limit = try c.contractOptionalInt(.limit, field: "limit", in: 1...ClaudeTranscriptLimits.maxSessionLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case limit
    }
}
