import Foundation

/// Parameters for `feed.reply`.
///
/// Permission and plan replies carry a `mode` from ``FeedItemKind/replyModes``; question
/// replies carry `selections` (option labels). Decoding enforces the shape per kind; the
/// relay additionally checks the item's `available_modes` and questions before calling cmux.
public struct FeedReplyRequest: Codable, Sendable, Equatable {
    /// The pending item's `request_id`.
    public var requestId: String
    /// The pending item's kind.
    public var kind: FeedItemKind
    /// Permission or plan mode.
    public var mode: String?
    /// Question answer: option labels.
    public var selections: [String]?

    /// Creates a reply request.
    public init(requestId: String, kind: FeedItemKind, mode: String? = nil, selections: [String]? = nil) {
        self.requestId = requestId; self.kind = kind; self.mode = mode; self.selections = selections
    }

    /// Decodes and validates a reply request.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.contractText(.requestId, field: "request_id", maxCharacters: FeedLimits.maxRequestIdCharacters)
        kind = try c.contractRequired(FeedItemKind.self, .kind, field: "kind")
        mode = try c.contractOptionalText(.mode, field: "mode")
        selections = try c.contractOptional([String].self, .selections, field: "selections")

        switch kind {
        case .permission, .plan:
            guard selections == nil else { throw RemoteProtocolError.invalidField("selections") }
            guard let mode else { throw RemoteProtocolError.missingField("mode") }
            guard kind.replyModes.contains(mode) else { throw RemoteProtocolError.invalidField("mode") }
        case .question:
            guard mode == nil else { throw RemoteProtocolError.invalidField("mode") }
            guard let selections else { throw RemoteProtocolError.missingField("selections") }
            guard selections.count <= FeedLimits.maxSelections,
                  selections.allSatisfy({ !$0.isEmpty && $0.count <= FeedLimits.maxOptionLabelCharacters })
            else { throw RemoteProtocolError.invalidField("selections") }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case requestId, kind, mode, selections
    }
}
