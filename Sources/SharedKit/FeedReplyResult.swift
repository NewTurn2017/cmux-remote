import Foundation

/// Result of `feed.reply`: confirms which request cmux accepted the answer for.
public struct FeedReplyResult: Codable, Sendable, Equatable {
    /// The answered item's `request_id`.
    public var requestId: String
    /// The answered item's kind.
    public var kind: FeedItemKind

    /// Creates a reply result.
    public init(requestId: String, kind: FeedItemKind) {
        self.requestId = requestId; self.kind = kind
    }

    /// Decodes and validates a reply result.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.contractText(.requestId, field: "request_id", maxCharacters: FeedLimits.maxRequestIdCharacters)
        kind = try c.contractRequired(FeedItemKind.self, .kind, field: "kind")
    }

    private enum CodingKeys: String, CodingKey {
        case requestId, kind
    }
}
