import Foundation
import SharedKit

/// Turns raw cmux `feed.list` items into contract items the phone can decode.
///
/// Follows the resolvable-item rules of cmux's bundled feed TUI: the five required keys, a
/// `pending` status, a `request_id`, and one of three kinds. Free text is cut to the contract
/// limits at a character boundary. Option labels and ids are never cut, because a reply must
/// echo the label exactly, so a question item that exceeds those limits is dropped instead.
enum FeedItemTranslator {
    /// Why a raw item was left out. Raw values are safe to log.
    enum Drop: String, Error, CaseIterable, Sendable {
        case malformed
        case notPending = "not_pending"
        case noRequestId = "no_request_id"
        case oversizedRequestId = "oversized_request_id"
        case unknownKind = "unknown_kind"
        case oversizedQuestion = "oversized_question"
    }

    static let defaultQuestionPrompt = "Answer the agent question."

    static func translate(_ raw: JSONValue) -> Result<FeedPendingItem, Drop> {
        guard case .object(let fields) = raw,
              let id = text(fields, "id"),
              let workstreamId = text(fields, "workstream_id"),
              let source = text(fields, "source"),
              let rawKind = text(fields, "kind"),
              let status = text(fields, "status")
        else { return .failure(.malformed) }
        guard status == "pending" else { return .failure(.notPending) }
        guard let requestId = text(fields, "request_id") else { return .failure(.noRequestId) }
        guard requestId.count <= FeedLimits.maxRequestIdCharacters else { return .failure(.oversizedRequestId) }

        let kind: FeedItemKind
        switch rawKind {
        case "permissionRequest": kind = .permission
        case "exitPlan": kind = .plan
        case "question": kind = .question
        default: return .failure(.unknownKind)
        }

        var item = FeedPendingItem(
            id: id, requestId: requestId, kind: kind, source: source, workstreamId: workstreamId,
            createdAt: createdAt(fields),
            title: text(fields, "title").map { cut($0, maxCharacters: FeedLimits.maxTitleCharacters).text },
            cwd: text(fields, "cwd").map { cut($0, maxCharacters: FeedLimits.maxCwdCharacters).text }
        )
        switch kind {
        case .permission:
            item.availableModes = FeedLimits.permissionModes
            item.toolName = text(fields, "tool_name").map { cut($0, maxCharacters: FeedLimits.maxToolNameCharacters).text }
            if let input = toolInputText(fields["tool_input"]) {
                let clipped = cut(input, maxUTF8Bytes: FeedLimits.maxToolInputBytes)
                item.toolInput = clipped.text
                item.toolInputTruncated = clipped.truncated ? true : nil
            }
        case .plan:
            item.availableModes = FeedLimits.planModes
            if let mode = text(fields, "default_mode"), FeedLimits.planModes.contains(mode) {
                item.defaultMode = mode
            }
            if let plan = text(fields, "plan_summary") ?? text(fields, "plan") {
                let clipped = cut(plan, maxUTF8Bytes: FeedLimits.maxPlanTextBytes)
                item.planText = clipped.text
                item.planTextTruncated = clipped.truncated ? true : nil
            }
        case .question:
            guard let questions = questions(fields) else { return .failure(.oversizedQuestion) }
            item.questions = questions
        }
        return .success(item)
    }

    /// Orders items newest first, then by id descending, as the feed TUI does.
    static func newestFirst(_ lhs: FeedPendingItem, _ rhs: FeedPendingItem) -> Bool {
        let left = lhs.createdAt ?? 0
        let right = rhs.createdAt ?? 0
        return left != right ? left > right : lhs.id > rhs.id
    }

    /// Keeps the leading items whose encoded size fits `budget` bytes.
    static func fitToBudget(_ items: [FeedPendingItem], budget: Int) -> (kept: [FeedPendingItem], omitted: Int) {
        let encoder = SharedKitJSON.snakeCaseEncoder
        var used = 64
        for (index, item) in items.enumerated() {
            let size = ((try? encoder.encode(item).count) ?? budget) + 1
            if used + size > budget { return (Array(items[..<index]), items.count - index) }
            used += size
        }
        return (items, 0)
    }

    /// Whether `selections` answers `questions` under the relay's selection rules.
    ///
    /// One question: no options takes an empty answer, single choice takes exactly one label,
    /// multiple choice takes one or more distinct labels. Several questions: every question must
    /// be single choice and gets one label, in question order.
    static func selectionsAnswer(_ questions: [FeedQuestion], _ selections: [String]) -> Bool {
        if questions.count == 1, let question = questions.first {
            let labels = Set(question.options.map(\.label))
            if question.options.isEmpty { return selections.isEmpty }
            guard selections.allSatisfy(labels.contains) else { return false }
            if question.multiSelect {
                return !selections.isEmpty && Set(selections).count == selections.count
            }
            return selections.count == 1
        }
        guard questions.count > 1,
              !questions.contains(where: \.multiSelect),
              selections.count == questions.count
        else { return false }
        return zip(questions, selections).allSatisfy { question, label in
            question.options.contains { $0.label == label }
        }
    }

    // MARK: - Fields

    private static func text(_ fields: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let value)? = fields[key], !value.isEmpty else { return nil }
        return value
    }

    private static func flag(_ value: JSONValue?) -> Bool {
        if case .bool(true)? = value { return true }
        return false
    }

    private static func createdAt(_ fields: [String: JSONValue]) -> Int64? {
        let raw = text(fields, "created_at") ?? text(fields, "createdAt") ?? text(fields, "timestamp") ?? text(fields, "time")
        guard let raw else { return nil }
        let date = (try? Date(raw, strategy: .iso8601))
            ?? (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        guard let date else { return nil }
        return Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }

    private static func toolInputText(_ value: JSONValue?) -> String? {
        switch value {
        case nil, .null?:
            return nil
        case .string(let text)?:
            return text.isEmpty ? nil : text
        case let other?:
            guard let data = try? SharedKitJSON.deterministicEncoder.encode(other) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Questions in TUI order, or nil when ids, labels, or counts exceed the contract limits.
    private static func questions(_ fields: [String: JSONValue]) -> [FeedQuestion]? {
        var parsed: [FeedQuestion] = []
        if case .array(let rawQuestions)? = fields["questions"] {
            for (index, rawQuestion) in rawQuestions.enumerated() {
                guard case .object(let question) = rawQuestion else { continue }
                let prompt = text(question, "prompt") ?? text(question, "question") ?? text(question, "header")
                let options = self.options(question["options"])
                if prompt == nil && options.isEmpty { continue }
                parsed.append(FeedQuestion(
                    id: text(question, "id") ?? "question-\(index + 1)",
                    prompt: cut(prompt ?? defaultQuestionPrompt, maxUTF8Bytes: FeedLimits.maxQuestionPromptBytes).text,
                    multiSelect: flag(question["multi_select"]) || flag(question["multiSelect"]),
                    options: options
                ))
            }
        }
        if parsed.isEmpty {
            let prompt = text(fields, "question_prompt") ?? text(fields, "title") ?? defaultQuestionPrompt
            parsed = [FeedQuestion(
                id: "question-1",
                prompt: cut(prompt, maxUTF8Bytes: FeedLimits.maxQuestionPromptBytes).text,
                multiSelect: flag(fields["question_multi_select"]),
                options: options(fields["question_options"])
            )]
        }
        let withinLimits = parsed.count <= FeedLimits.maxQuestions && parsed.allSatisfy { question in
            question.id.count <= FeedLimits.maxQuestionIdCharacters
                && question.options.count <= FeedLimits.maxOptionsPerQuestion
                && question.options.allSatisfy {
                    $0.id.count <= FeedLimits.maxQuestionIdCharacters
                        && $0.label.count <= FeedLimits.maxOptionLabelCharacters
                }
        }
        return withinLimits ? parsed : nil
    }

    private static func options(_ value: JSONValue?) -> [FeedOption] {
        guard case .array(let rawOptions)? = value else { return [] }
        return rawOptions.compactMap { rawOption in
            guard case .object(let option) = rawOption,
                  let id = text(option, "id"),
                  let label = text(option, "label")
            else { return nil }
            return FeedOption(id: id, label: label)
        }
    }

    // MARK: - Cutting

    static func cut(_ text: String, maxCharacters: Int) -> (text: String, truncated: Bool) {
        guard text.count > maxCharacters else { return (text, false) }
        return (String(text.prefix(maxCharacters)), true)
    }

    static func cut(_ text: String, maxUTF8Bytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > maxUTF8Bytes else { return (text, false) }
        var bytes = 0
        var end = text.startIndex
        for index in text.indices {
            let width = text[index].utf8.count
            if bytes + width > maxUTF8Bytes { break }
            bytes += width
            end = text.index(after: index)
        }
        return (String(text[..<end]), true)
    }
}
