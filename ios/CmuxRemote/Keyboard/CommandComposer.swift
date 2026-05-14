import Foundation
import SharedKit

public struct CommandComposer: Equatable {
    public var draft: String = ""
    public private(set) var history: [String] = []
    public var activeModifiers: Set<KeyModifier> = []
    public var isSending = false
    public var errorMessage: String?

    private var historyCursor: Int?
    private let maxHistoryCount: Int

    public init(maxHistoryCount: Int = 80) {
        self.maxHistoryCount = maxHistoryCount
    }

    public var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    public mutating func insert(_ text: String) {
        draft.append(text)
        errorMessage = nil
        historyCursor = nil
    }

    public mutating func paste(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        insert(text)
    }

    public mutating func toggle(_ modifier: KeyModifier) {
        if activeModifiers.contains(modifier) {
            activeModifiers.remove(modifier)
        } else {
            activeModifiers.insert(modifier)
        }
        errorMessage = nil
    }

    public mutating func key(_ name: String) -> Key {
        defer { activeModifiers.removeAll() }
        return .named(name, modifiers: activeModifiers)
    }

    public mutating func previousHistory() {
        guard !history.isEmpty else { return }
        let nextCursor: Int
        if let historyCursor {
            nextCursor = max(historyCursor - 1, 0)
        } else {
            nextCursor = history.count - 1
        }
        historyCursor = nextCursor
        draft = history[nextCursor]
    }

    public mutating func nextHistory() {
        guard let historyCursor else { return }
        let nextCursor = historyCursor + 1
        if nextCursor >= history.count {
            self.historyCursor = nil
            draft = ""
        } else {
            self.historyCursor = nextCursor
            draft = history[nextCursor]
        }
    }

    public mutating func beginSubmit() -> String? {
        let command = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !isSending else { return nil }
        isSending = true
        errorMessage = nil
        return command
    }

    public mutating func completeSubmit(_ command: String) {
        record(command)
        draft = ""
        historyCursor = nil
        isSending = false
    }

    public mutating func failSubmit(_ error: Error) {
        errorMessage = String(describing: error)
        isSending = false
    }

    public mutating func clearError() {
        errorMessage = nil
    }

    public mutating func submit(send: (String) async throws -> Void) async {
        guard let command = beginSubmit() else { return }
        do {
            try await send(command.hasSuffix("\n") ? command : command + "\n")
            completeSubmit(command)
        } catch {
            failSubmit(error)
        }
    }

    private mutating func record(_ command: String) {
        if history.last != command {
            history.append(command)
        }
        if history.count > maxHistoryCount {
            history.removeFirst(history.count - maxHistoryCount)
        }
    }
}
