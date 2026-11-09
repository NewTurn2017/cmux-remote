import Foundation
import SharedKit

/// One transcript block ready to draw. Claude's text is parsed as Markdown once, when its page arrives.
struct ClaudeTranscriptDisplayBlock: Equatable, Sendable {
    let block: ClaudeTranscriptBlock
    let markdown: [MarkdownBlock]?

    init(block: ClaudeTranscriptBlock, role: ClaudeTranscriptRole) {
        self.block = block
        if role == .assistant, block.kind == .text, let text = block.text {
            markdown = MarkdownBlockParser.parse(text)
        } else {
            markdown = nil
        }
    }

    var textBytes: Int {
        (block.text?.utf8.count ?? 0) + (block.summary?.utf8.count ?? 0)
    }
}

/// One displayed message. Neighboring assistant entries with the same `messageId` become one row.
struct ClaudeTranscriptRow: Identifiable, Equatable, Sendable {
    let id: String
    let role: ClaudeTranscriptRole
    let timestamp: Int64?
    let messageId: String?
    var blocks: [ClaudeTranscriptDisplayBlock]

    init(entry: ClaudeTranscriptEntry) {
        id = entry.id
        role = entry.role
        timestamp = entry.timestamp
        messageId = entry.messageId
        blocks = entry.blocks.map { ClaudeTranscriptDisplayBlock(block: $0, role: entry.role) }
    }

    var textBytes: Int { blocks.reduce(0) { $0 + $1.textBytes } }

    /// A user row that only carries tool output, drawn like Claude's tool rows rather than as a message.
    var isToolResultOnly: Bool {
        role == .user && blocks.allSatisfy { $0.block.kind == .toolResult }
    }

    func continues(_ previous: ClaudeTranscriptRow) -> Bool {
        role == .assistant && previous.role == .assistant && messageId != nil && messageId == previous.messageId
    }
}

/// The loaded part of one transcript, oldest to newest, kept under fixed memory caps.
///
/// Pages arrive newest first. Older pages are added above; when the caps are exceeded the newest
/// rows are dropped and ``newerTrimmed`` asks the view to offer a jump back to the latest page.
struct ClaudeTranscriptTimeline: Equatable, Sendable {
    static let maxRows = 600
    static let maxTextBytes = 4 * 1_024 * 1_024

    enum LatestOutcome: Equatable {
        case unchanged
        case appended
        case replaced
    }

    private(set) var rows: [ClaudeTranscriptRow] = []
    /// Byte cursor for the next older page; nil before the first page and once the start is reached.
    private(set) var olderBefore: Int64?
    private(set) var reachedStart = false
    private(set) var newerTrimmed = false
    private(set) var textBytes = 0

    private let maxRows: Int
    private let maxTextBytes: Int

    init(maxRows: Int = ClaudeTranscriptTimeline.maxRows, maxTextBytes: Int = ClaudeTranscriptTimeline.maxTextBytes) {
        self.maxRows = maxRows
        self.maxTextBytes = maxTextBytes
    }

    /// Joins neighboring assistant rows that belong to one message, keeping the earlier row's id.
    static func merged(_ rows: [ClaudeTranscriptRow]) -> [ClaudeTranscriptRow] {
        var result: [ClaudeTranscriptRow] = []
        result.reserveCapacity(rows.count)
        for row in rows {
            if let last = result.last, row.continues(last) {
                result[result.count - 1].blocks += row.blocks
            } else {
                result.append(row)
            }
        }
        return result
    }

    mutating func replaceWithLatest(_ page: [ClaudeTranscriptRow], before: Int64?) {
        rows = Self.merged(page)
        olderBefore = before
        reachedStart = before == nil
        newerTrimmed = false
        recount()
        trimNewestToCaps()
    }

    /// Adds an older page above the loaded rows and returns the id of the previously first row.
    /// A message split by the page boundary is joined into that row, which keeps its id so the
    /// view can hold it in place while the older rows appear above it.
    @discardableResult
    mutating func prependOlder(_ page: [ClaudeTranscriptRow], before: Int64?) -> String? {
        let oldIDs = Set(rows.map(\.id))
        let oldFirst = rows.first?.id
        var older = Self.merged(page.filter { !oldIDs.contains($0.id) })
        var newer = rows
        if let split = older.last, let first = newer.first, first.continues(split) {
            newer[0].blocks = split.blocks + first.blocks
            older.removeLast()
        }
        rows = older + newer
        olderBefore = before
        reachedStart = before == nil
        recount()
        trimNewestToCaps()
        return oldFirst.flatMap { id in rows.contains { $0.id == id } ? id : nil }
    }

    /// Applies a fresh newest page: new rows are appended after the overlap and a growing last
    /// message is updated. Without an overlap, after trimming, or past the caps the newest page
    /// replaces everything.
    mutating func applyLatest(_ page: [ClaudeTranscriptRow], before: Int64?) -> LatestOutcome {
        let pageRows = Self.merged(page)
        guard !newerTrimmed, let last = rows.last,
              let overlap = pageRows.firstIndex(where: { $0.id == last.id })
        else {
            replaceWithLatest(page, before: before)
            return .replaced
        }
        var next = rows
        var changed = false
        if pageRows[overlap].blocks.count > last.blocks.count {
            next[next.count - 1] = pageRows[overlap]
            changed = true
        }
        let known = Set(next.map(\.id))
        let newer = pageRows[(overlap + 1)...].filter { !known.contains($0.id) }
        if !newer.isEmpty {
            next = Self.merged(next + newer)
            changed = true
        }
        guard changed else { return .unchanged }
        let nextBytes = next.reduce(0) { $0 + $1.textBytes }
        guard next.count <= maxRows, nextBytes <= maxTextBytes else {
            replaceWithLatest(page, before: before)
            return .replaced
        }
        rows = next
        textBytes = nextBytes
        return .appended
    }

    private mutating func recount() {
        textBytes = rows.reduce(0) { $0 + $1.textBytes }
    }

    private mutating func trimNewestToCaps() {
        while rows.count > 1, rows.count > maxRows || textBytes > maxTextBytes {
            textBytes -= rows.removeLast().textBytes
            newerTrimmed = true
        }
    }
}
