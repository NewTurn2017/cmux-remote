import Foundation

/// One option of a feed question. Replies send the option's `label`.
public struct FeedOption: Codable, Sendable, Equatable {
    /// Option identifier from cmux.
    public var id: String
    /// Option text shown to the user and sent back in `selections`.
    public var label: String

    /// Creates a feed option.
    public init(id: String, label: String) {
        self.id = id; self.label = label
    }

    /// Decodes and validates a feed option.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.contractText(.id, field: "id", maxCharacters: FeedLimits.maxQuestionIdCharacters)
        label = try c.contractText(.label, field: "label", maxCharacters: FeedLimits.maxOptionLabelCharacters)
    }

    private enum CodingKeys: String, CodingKey {
        case id, label
    }
}

/// One question of a feed question item.
public struct FeedQuestion: Codable, Sendable, Equatable {
    /// Question identifier from cmux, or `question-N` when cmux sent none.
    public var id: String
    /// Question text.
    public var prompt: String
    /// Whether more than one option may be selected.
    public var multiSelect: Bool
    /// Options in cmux order; empty when the question takes an empty answer.
    public var options: [FeedOption]

    /// Creates a feed question.
    public init(id: String, prompt: String, multiSelect: Bool, options: [FeedOption]) {
        self.id = id; self.prompt = prompt; self.multiSelect = multiSelect; self.options = options
    }

    /// Decodes and validates a feed question.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.contractText(.id, field: "id", maxCharacters: FeedLimits.maxQuestionIdCharacters)
        prompt = try c.contractText(.prompt, field: "prompt", maxUTF8Bytes: FeedLimits.maxQuestionPromptBytes)
        multiSelect = try c.contractRequired(Bool.self, .multiSelect, field: "multi_select")
        options = try c.contractRequired([FeedOption].self, .options, field: "options")
        guard options.count <= FeedLimits.maxOptionsPerQuestion else { throw RemoteProtocolError.invalidField("options") }
    }

    private enum CodingKeys: String, CodingKey {
        case id, prompt, multiSelect, options
    }
}

/// A cmux feed request that can be answered from the phone.
public struct FeedPendingItem: Codable, Sendable, Equatable {
    /// cmux feed item identifier.
    public var id: String
    /// Identifier sent back in `feed.reply`.
    public var requestId: String
    /// Question, permission, or plan.
    public var kind: FeedItemKind
    /// Agent that raised the request, such as `claude`.
    public var source: String
    /// cmux workstream that owns the request.
    public var workstreamId: String
    /// Creation time in milliseconds since 1970, omitted when cmux sent none.
    public var createdAt: Int64?
    /// Title from cmux, omitted when cmux sent none.
    public var title: String?
    /// Agent working directory.
    public var cwd: String?
    /// Permission: tool name.
    public var toolName: String?
    /// Permission: tool input as text; objects arrive as key-sorted JSON.
    public var toolInput: String?
    /// Permission: whether ``toolInput`` was cut at ``FeedLimits/maxToolInputBytes``.
    public var toolInputTruncated: Bool?
    /// Permission and plan: reply modes this item accepts.
    public var availableModes: [String]?
    /// Plan: mode used by the default action.
    public var defaultMode: String?
    /// Plan: the proposed plan text.
    public var planText: String?
    /// Plan: whether ``planText`` was cut at ``FeedLimits/maxPlanTextBytes``.
    public var planTextTruncated: Bool?
    /// Question: the questions in order.
    public var questions: [FeedQuestion]?

    /// Creates a pending feed item.
    public init(
        id: String, requestId: String, kind: FeedItemKind, source: String, workstreamId: String,
        createdAt: Int64? = nil, title: String? = nil, cwd: String? = nil,
        toolName: String? = nil, toolInput: String? = nil, toolInputTruncated: Bool? = nil,
        availableModes: [String]? = nil, defaultMode: String? = nil,
        planText: String? = nil, planTextTruncated: Bool? = nil, questions: [FeedQuestion]? = nil
    ) {
        self.id = id; self.requestId = requestId; self.kind = kind; self.source = source
        self.workstreamId = workstreamId; self.createdAt = createdAt; self.title = title; self.cwd = cwd
        self.toolName = toolName; self.toolInput = toolInput; self.toolInputTruncated = toolInputTruncated
        self.availableModes = availableModes; self.defaultMode = defaultMode
        self.planText = planText; self.planTextTruncated = planTextTruncated; self.questions = questions
    }

    /// Decodes and validates a pending feed item. Unknown kinds and modes are rejected.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.contractText(.id, field: "id")
        requestId = try c.contractText(.requestId, field: "request_id", maxCharacters: FeedLimits.maxRequestIdCharacters)
        kind = try c.contractRequired(FeedItemKind.self, .kind, field: "kind")
        source = try c.contractText(.source, field: "source")
        workstreamId = try c.contractText(.workstreamId, field: "workstream_id")
        createdAt = try c.contractOptional(Int64.self, .createdAt, field: "created_at")
        title = try c.contractOptionalText(.title, field: "title", maxCharacters: FeedLimits.maxTitleCharacters)
        cwd = try c.contractOptionalText(.cwd, field: "cwd", maxCharacters: FeedLimits.maxCwdCharacters)
        toolName = try c.contractOptionalText(.toolName, field: "tool_name", maxCharacters: FeedLimits.maxToolNameCharacters)
        toolInput = try c.contractOptionalText(.toolInput, field: "tool_input", maxUTF8Bytes: FeedLimits.maxToolInputBytes)
        toolInputTruncated = try c.contractOptional(Bool.self, .toolInputTruncated, field: "tool_input_truncated")
        availableModes = try c.contractOptional([String].self, .availableModes, field: "available_modes")
        if let availableModes, !availableModes.allSatisfy(kind.replyModes.contains) {
            throw RemoteProtocolError.invalidField("available_modes")
        }
        defaultMode = try c.contractOptionalText(.defaultMode, field: "default_mode")
        if let defaultMode, !FeedLimits.planModes.contains(defaultMode) {
            throw RemoteProtocolError.invalidField("default_mode")
        }
        planText = try c.contractOptionalText(.planText, field: "plan_text", maxUTF8Bytes: FeedLimits.maxPlanTextBytes)
        planTextTruncated = try c.contractOptional(Bool.self, .planTextTruncated, field: "plan_text_truncated")
        questions = try c.contractOptional([FeedQuestion].self, .questions, field: "questions")
        if let questions, questions.count > FeedLimits.maxQuestions {
            throw RemoteProtocolError.invalidField("questions")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, requestId, kind, source, workstreamId, createdAt, title, cwd
        case toolName, toolInput, toolInputTruncated, availableModes, defaultMode
        case planText, planTextTruncated, questions
    }
}

/// Result of `feed.pending.list`: answerable items, newest first.
public struct FeedPendingListResult: Codable, Sendable, Equatable {
    /// Answerable items, newest first.
    public var items: [FeedPendingItem]
    /// Whether older items were left out to keep the response under the size limit.
    public var truncated: Bool
    /// How many items were left out, present only when ``truncated`` is true.
    public var omittedCount: Int?

    /// Creates a pending-list result.
    public init(items: [FeedPendingItem], truncated: Bool, omittedCount: Int? = nil) {
        self.items = items; self.truncated = truncated; self.omittedCount = omittedCount
    }

    /// Decodes and validates a pending-list result.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.contractRequired([FeedPendingItem].self, .items, field: "items")
        truncated = try c.contractRequired(Bool.self, .truncated, field: "truncated")
        omittedCount = try c.contractOptionalInt(.omittedCount, field: "omitted_count", in: 0...Int.max)
    }

    private enum CodingKeys: String, CodingKey {
        case items, truncated, omittedCount
    }
}
