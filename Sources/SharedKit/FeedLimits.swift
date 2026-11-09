import Foundation

/// Fixed bounds of the `feed.pending.list` and `feed.reply` contract.
public enum FeedLimits {
    /// Items returned when `feed.pending.list` has no `limit`.
    public static let defaultListLimit = 50
    /// Largest accepted `limit` for `feed.pending.list`.
    public static let maxListLimit = 100
    /// Longest accepted `request_id`, in characters.
    public static let maxRequestIdCharacters = 256
    /// Longest item title, in characters.
    public static let maxTitleCharacters = 512
    /// Longest item working directory, in characters.
    public static let maxCwdCharacters = 1_024
    /// Longest permission tool name, in characters.
    public static let maxToolNameCharacters = 128
    /// Largest permission tool input, in UTF-8 bytes.
    public static let maxToolInputBytes = 16 * 1_024
    /// Largest plan text, in UTF-8 bytes.
    public static let maxPlanTextBytes = 64 * 1_024
    /// Most questions in one question item.
    public static let maxQuestions = 10
    /// Longest question or option id, in characters.
    public static let maxQuestionIdCharacters = 256
    /// Largest question prompt, in UTF-8 bytes.
    public static let maxQuestionPromptBytes = 2 * 1_024
    /// Most options in one question.
    public static let maxOptionsPerQuestion = 32
    /// Longest option label, in characters.
    public static let maxOptionLabelCharacters = 512
    /// Most labels in one `feed.reply` selections array.
    public static let maxSelections = 50
    /// Modes the relay accepts for a permission reply. `all` and `bypass` are never accepted.
    public static let permissionModes: [String] = ["once", "always", "deny"]
    /// Modes the relay accepts for a plan reply. `ultraplan` and `bypassPermissions` are never accepted.
    public static let planModes: [String] = ["autoAccept", "manual", "deny"]
    /// Largest encoded response, so one frame stays under 1 MiB.
    public static let maxResponseBytes = 737_280
    /// Bytes kept free inside ``maxResponseBytes`` for the RPC envelope.
    public static let responseEnvelopeReserveBytes = 8 * 1_024
}

/// The kind of a pending feed request.
public enum FeedItemKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// An agent question answered with option labels.
    case question
    /// A tool permission request answered with a mode.
    case permission
    /// A plan approval answered with a mode.
    case plan

    /// Reply modes the contract allows for this kind; empty for questions.
    public var replyModes: [String] {
        switch self {
        case .question: return []
        case .permission: return FeedLimits.permissionModes
        case .plan: return FeedLimits.planModes
        }
    }

    /// Decodes a known kind and rejects unknown values with `invalid_field`.
    public init(from decoder: Decoder) throws {
        guard let raw = try? decoder.singleValueContainer().decode(String.self),
              let kind = FeedItemKind(rawValue: raw)
        else { throw RemoteProtocolError.invalidField("kind") }
        self = kind
    }
}
