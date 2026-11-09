import Foundation
import SharedKit

/// Turns one Claude JSONL line into a displayed transcript entry.
///
/// Only non-sidechain, non-meta `user` and `assistant` lines are shown. Thinking, signatures,
/// images, advisor results, and unknown block types are dropped; text and tool output are cut
/// at the contract limits, and one entry never encodes to more than ``maxEntryBytes``.
enum ClaudeTranscriptRenderer {
    enum Outcome: Equatable {
        case entry(ClaudeTranscriptEntry)
        case skipped
        case broken
    }

    static let maxEntryBytes = 64 * 1_024

    static func render(_ line: Data) -> Outcome {
        guard case .object(let fields)? = try? JSONDecoder().decode(JSONValue.self, from: line) else { return .broken }
        guard case .string(let type)? = fields["type"], let role = ClaudeTranscriptRole(rawValue: type) else { return .skipped }
        if fields["isSidechain"] == .bool(true) || fields["isMeta"] == .bool(true) { return .skipped }
        guard case .string(let uuid)? = fields["uuid"], !uuid.isEmpty,
              case .object(let message)? = fields["message"]
        else { return .skipped }

        var blocks: [ClaudeTranscriptBlock] = []
        switch message["content"] {
        case .string(let text)?:
            if let block = textBlock(text) { blocks.append(block) }
        case .array(let items)?:
            for case .object(let item) in items {
                if let block = displayBlock(item) { blocks.append(block) }
            }
        default:
            break
        }
        guard !blocks.isEmpty else { return .skipped }
        if blocks.count > ClaudeTranscriptLimits.maxBlocksPerEntry {
            blocks = Array(blocks.prefix(ClaudeTranscriptLimits.maxBlocksPerEntry))
            blocks[blocks.count - 1].truncated = true
        }

        var messageId: String?
        if role == .assistant, case .string(let id)? = message["id"], !id.isEmpty { messageId = id }
        let entry = ClaudeTranscriptEntry(
            id: uuid, role: role, timestamp: epochMilliseconds(fields["timestamp"]), messageId: messageId, blocks: blocks
        )
        return .entry(fitted(entry))
    }

    static func encodedSize(_ entry: ClaudeTranscriptEntry) -> Int {
        (try? SharedKitJSON.snakeCaseEncoder.encode(entry).count) ?? Int.max
    }

    /// Drops trailing blocks, then halves the last text, until the entry fits ``maxEntryBytes``.
    static func fitted(_ entry: ClaudeTranscriptEntry) -> ClaudeTranscriptEntry {
        var entry = entry
        while encodedSize(entry) > maxEntryBytes {
            let last = entry.blocks.count - 1
            if last > 0 {
                entry.blocks.removeLast()
                entry.blocks[last - 1].truncated = true
            } else if let text = entry.blocks[0].text, text.count > 1 {
                entry.blocks[0].text = FeedItemTranslator.cut(text, maxCharacters: text.count / 2).text
                entry.blocks[0].truncated = true
            } else {
                break
            }
        }
        return entry
    }

    // MARK: - Blocks

    private static func displayBlock(_ item: [String: JSONValue]) -> ClaudeTranscriptBlock? {
        guard case .string(let type)? = item["type"] else { return nil }
        switch type {
        case "text":
            guard case .string(let text)? = item["text"] else { return nil }
            return textBlock(text)
        case "tool_use", "server_tool_use":
            guard case .string(let name)? = item["name"], !name.isEmpty else { return nil }
            let toolName = FeedItemTranslator.cut(name, maxCharacters: ClaudeTranscriptLimits.maxToolNameCharacters)
            var block = ClaudeTranscriptBlock(kind: .toolUse, toolName: toolName.text, truncated: toolName.truncated ? true : nil)
            if let summary = toolInputSummary(name: name, input: item["input"]) {
                let cut = FeedItemTranslator.cut(oneLine(summary), maxCharacters: ClaudeTranscriptLimits.maxToolUseSummaryCharacters)
                block.summary = cut.text
                if cut.truncated { block.truncated = true }
            }
            return block
        case "tool_result":
            var block = ClaudeTranscriptBlock(kind: .toolResult, isError: item["is_error"] == .bool(true) ? true : nil)
            let output = toolResultText(item["content"])
            if !output.isEmpty {
                let cut = FeedItemTranslator.cut(output, maxUTF8Bytes: ClaudeTranscriptLimits.maxToolResultSummaryBytes)
                block.summary = cut.text
                if cut.truncated { block.truncated = true }
            }
            return block
        default:
            return nil
        }
    }

    private static func textBlock(_ text: String) -> ClaudeTranscriptBlock? {
        guard !text.isEmpty else { return nil }
        let cut = FeedItemTranslator.cut(text, maxUTF8Bytes: ClaudeTranscriptLimits.maxTextBytes)
        guard !cut.text.isEmpty else { return nil }
        return ClaudeTranscriptBlock(kind: .text, text: cut.text, truncated: cut.truncated ? true : nil)
    }

    private static func toolResultText(_ content: JSONValue?) -> String {
        switch content {
        case .string(let text)?:
            return text
        case .array(let items)?:
            var parts: [String] = []
            for case .object(let item) in items {
                switch item["type"] {
                case .string("text")?:
                    if case .string(let text)? = item["text"] { parts.append(text) }
                case .string("image")?:
                    parts.append("[image]")
                default:
                    break
                }
            }
            return parts.joined(separator: "\n")
        default:
            return ""
        }
    }

    private static func toolInputSummary(name: String, input: JSONValue?) -> String? {
        guard case .object(let fields)? = input else { return nil }
        func string(_ key: String) -> String? {
            guard case .string(let value)? = fields[key], !value.isEmpty else { return nil }
            return value
        }
        switch name {
        case "Bash":
            return string("command")
        case "Read", "Edit", "Write", "MultiEdit":
            return string("file_path")
        case "NotebookEdit":
            return string("notebook_path") ?? string("file_path")
        case "Grep":
            guard let pattern = string("pattern") else { return nil }
            return string("path").map { "\(pattern) in \($0)" } ?? pattern
        case "Glob":
            return string("pattern")
        case "WebFetch":
            return string("url")
        case "WebSearch":
            return string("query")
        case "Task", "Agent":
            return string("description")
        case "TodoWrite":
            guard case .array(let todos)? = fields["todos"] else { return nil }
            return "\(todos.count) todos"
        default:
            return fields.keys.sorted().lazy.compactMap(string).first
        }
    }

    private static func oneLine(_ text: String) -> String {
        String(text.map { $0.isNewline ? " " : $0 })
    }

    private static func epochMilliseconds(_ value: JSONValue?) -> Int64? {
        guard case .string(let raw)? = value else { return nil }
        let date = (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(raw, strategy: .iso8601))
        return date.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) }
    }
}
