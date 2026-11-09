import Foundation

/// Parameters for `feed.pending.list`.
public struct FeedPendingListRequest: Codable, Sendable, Equatable {
    /// Most items to return; the relay uses ``FeedLimits/defaultListLimit`` when omitted.
    public var limit: Int?

    /// Creates a pending-list request.
    public init(limit: Int? = nil) {
        self.limit = limit
    }

    /// Decodes and validates a pending-list request.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limit = try c.contractOptionalInt(.limit, field: "limit", in: 1...FeedLimits.maxListLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case limit
    }
}
