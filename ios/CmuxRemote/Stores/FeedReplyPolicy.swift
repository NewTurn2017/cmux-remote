import Foundation
import SharedKit

enum FeedReplyButton: String, CaseIterable, Sendable {
    case allowOnce
    case allowAlways
    case deny
    case approve
    case autoApprove
    case reject

    var kind: FeedItemKind {
        switch self {
        case .allowOnce, .allowAlways, .deny: return .permission
        case .approve, .autoApprove, .reject: return .plan
        }
    }

    func mode(for item: FeedPendingItem) -> String {
        switch self {
        case .allowOnce: return "once"
        case .allowAlways: return "always"
        case .deny, .reject: return "deny"
        case .approve: return FeedReplyPolicy.approveMode(defaultMode: item.defaultMode)
        case .autoApprove: return "autoAccept"
        }
    }

    /// Broad grants (`always`, `autoAccept`) ask for confirmation before sending.
    func requiresConfirmation(for item: FeedPendingItem) -> Bool {
        let mode = mode(for: item)
        return mode == "always" || mode == "autoAccept"
    }

    var title: String {
        switch self {
        case .allowOnce: return String(localized: "feed.reply.allow_once", defaultValue: "Allow")
        case .allowAlways: return String(localized: "feed.reply.allow_always", defaultValue: "Always allow")
        case .deny: return String(localized: "feed.reply.deny", defaultValue: "Deny")
        case .approve: return String(localized: "feed.reply.approve", defaultValue: "Approve")
        case .autoApprove: return String(localized: "feed.reply.auto_approve", defaultValue: "Auto-approve")
        case .reject: return String(localized: "feed.reply.reject", defaultValue: "Reject")
        }
    }
}

enum FeedReplyPolicy {
    /// Plan approval follows the item's default mode when it is a plain approval, else `manual`.
    static func approveMode(defaultMode: String?) -> String {
        if let defaultMode, defaultMode == "autoAccept" || defaultMode == "manual" {
            return defaultMode
        }
        return "manual"
    }

    /// The app's buttons for the item's kind whose mode the item accepts. When two buttons
    /// would send the same mode (approve with an `autoAccept` default), only the first stays.
    static func buttons(for item: FeedPendingItem) -> [FeedReplyButton] {
        let accepted = item.availableModes ?? item.kind.replyModes
        var seen = Set<String>()
        return FeedReplyButton.allCases.filter { button in
            guard button.kind == item.kind else { return false }
            let mode = button.mode(for: item)
            return accepted.contains(mode) && seen.insert(mode).inserted
        }
    }

    static func request(for button: FeedReplyButton, item: FeedPendingItem) -> FeedReplyRequest {
        FeedReplyRequest(requestId: item.requestId, kind: item.kind, mode: button.mode(for: item))
    }
}

/// Answer being composed on a question card, following the relay's selections rules:
/// one question takes one label (or one or more when multi-select, or none when it has no
/// options); several single-select questions take one label each in question order; several
/// questions where any is multi-select or has no options must be answered on the Mac.
struct FeedQuestionDraft: Equatable {
    enum Outcome: Equatable {
        case ready(selections: [String])
        case incomplete
        case answerOnMac
    }

    let questions: [FeedQuestion]
    private(set) var chosen: [[Int]]

    init(questions: [FeedQuestion]) {
        self.questions = questions
        self.chosen = Array(repeating: [], count: questions.count)
    }

    static func requiresMac(_ questions: [FeedQuestion]) -> Bool {
        if questions.isEmpty { return true }
        if questions.count == 1 { return false }
        return questions.contains { $0.multiSelect || $0.options.isEmpty }
    }

    var requiresMac: Bool { Self.requiresMac(questions) }

    func isSelected(question: Int, option: Int) -> Bool {
        chosen.indices.contains(question) && chosen[question].contains(option)
    }

    mutating func toggle(question: Int, option: Int) {
        guard questions.indices.contains(question),
              questions[question].options.indices.contains(option)
        else { return }
        if questions[question].multiSelect {
            if let index = chosen[question].firstIndex(of: option) {
                chosen[question].remove(at: index)
            } else {
                chosen[question].append(option)
                chosen[question].sort()
            }
        } else {
            chosen[question] = chosen[question] == [option] ? [] : [option]
        }
    }

    var outcome: Outcome {
        if requiresMac { return .answerOnMac }
        if questions.count == 1 {
            let question = questions[0]
            if question.options.isEmpty { return .ready(selections: []) }
            var labels: [String] = []
            for index in chosen[0] where !labels.contains(question.options[index].label) {
                labels.append(question.options[index].label)
            }
            if question.multiSelect {
                return labels.isEmpty ? .incomplete : .ready(selections: labels)
            }
            return labels.count == 1 ? .ready(selections: labels) : .incomplete
        }
        var labels: [String] = []
        for (index, question) in questions.enumerated() {
            guard chosen[index].count == 1 else { return .incomplete }
            labels.append(question.options[chosen[index][0]].label)
        }
        return .ready(selections: labels)
    }
}
