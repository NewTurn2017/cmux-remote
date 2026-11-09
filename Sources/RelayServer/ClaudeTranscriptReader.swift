import Darwin
import Foundation
import SharedKit

/// Reads Claude JSONL transcripts backward from an exclusive end offset, one page at a time.
///
/// The bytes after the last newline before `end` are always dropped: without `before` that is a
/// line Claude is still writing, and with `before` from an earlier page there are none. A line
/// longer than `maxLineBytes` is skipped without being held, and one request reads at most
/// `maxScanBytes`; when that budget runs out the page ends early and `before` still moves back,
/// so every page makes progress.
enum ClaudeTranscriptReader {
    struct Limits: Sendable {
        var blockBytes = ClaudeTranscriptLimits.readBlockBytes
        var maxLineBytes = ClaudeTranscriptLimits.maxLineBytes
        var maxScanBytes = ClaudeTranscriptLimits.maxScanBytesPerRequest
    }

    struct Line {
        let start: Int64
        /// Nil when the line was longer than `maxLineBytes` and skipped.
        let bytes: Data?
    }

    struct Scan: Equatable {
        var bytesRead = 0
        var peakHeldBytes = 0
        var skippedLongLines = 0
        var stoppedByCaller = false
        /// Where the next request resumes when the read budget ran out first.
        var budgetBefore: Int64?
    }

    struct Page: Equatable {
        var entries: [ClaudeTranscriptEntry]
        var before: Int64?
        var scan: Scan
        var brokenLines: Int
    }

    enum Failure: Error, Equatable {
        case readFailed
    }

    static func scanBackward(
        descriptor: Int32,
        end: Int64,
        limits: Limits = Limits(),
        onLine: (Line) -> Bool
    ) throws -> Scan {
        var scan = Scan()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: limits.blockBytes)
        defer { buffer.deallocate() }
        var position = end
        var inFragment = true
        var lineEnd: Int64 = 0
        var pieces: [Data] = []
        var held = 0
        var overflow = false

        func hold(from lower: Int, to upper: Int) {
            guard !overflow, upper > lower else { return }
            if held + (upper - lower) > limits.maxLineBytes {
                overflow = true
                pieces.removeAll()
                held = 0
                return
            }
            pieces.append(Data(bytes: buffer + lower, count: upper - lower))
            held += upper - lower
            scan.peakHeldBytes = max(scan.peakHeldBytes, held)
        }

        func finishLine(start: Int64) -> Bool {
            var bytes: Data?
            if overflow {
                scan.skippedLongLines += 1
            } else {
                var line = Data(capacity: held)
                for piece in pieces.reversed() { line.append(piece) }
                bytes = line
            }
            pieces.removeAll()
            held = 0
            overflow = false
            return onLine(Line(start: start, bytes: bytes))
        }

        while position > 0 {
            if scan.bytesRead >= limits.maxScanBytes {
                scan.budgetBefore = (inFragment || overflow) ? position : lineEnd + 1
                return scan
            }
            let count = Int(min(Int64(limits.blockBytes), position))
            let offset = position - Int64(count)
            guard preadRetryingEINTR(descriptor, buffer, count, off_t(offset)) == count else { throw Failure.readFailed }
            scan.bytesRead += count

            var segmentEnd = count
            var index = count - 1
            while index >= 0 {
                if buffer[index] == 0x0A {
                    let absolute = offset + Int64(index)
                    if inFragment {
                        inFragment = false
                    } else {
                        hold(from: index + 1, to: segmentEnd)
                        if !finishLine(start: absolute + 1) {
                            scan.stoppedByCaller = true
                            return scan
                        }
                    }
                    lineEnd = absolute
                    segmentEnd = index
                }
                index -= 1
            }
            if !inFragment { hold(from: 0, to: segmentEnd) }
            position = offset
        }
        if !inFragment, !finishLine(start: 0) { scan.stoppedByCaller = true }
        return scan
    }

    /// Reads the entries that end before `end`, newest first while scanning, returned oldest first.
    ///
    /// Neighboring assistant lines with the same message id merge into one entry while the merged
    /// entry still fits. The page stops at the first line that would start a new entry once
    /// `maxEntries` entries or `entryBytesBudget` encoded bytes are used; `before` is then the
    /// start of the oldest entry kept.
    static func readPage(
        descriptor: Int32,
        end: Int64,
        maxEntries: Int,
        entryBytesBudget: Int,
        limits: Limits = Limits()
    ) throws -> Page {
        var kept: [(entry: ClaudeTranscriptEntry, start: Int64, size: Int)] = []
        var used = 0
        var broken = 0
        let scan = try scanBackward(descriptor: descriptor, end: end, limits: limits) { line in
            guard let bytes = line.bytes else { return true }
            let entry: ClaudeTranscriptEntry
            switch ClaudeTranscriptRenderer.render(bytes) {
            case .broken: broken += 1; return true
            case .skipped: return true
            case .entry(let rendered): entry = rendered
            }
            if let newer = kept.last, entry.role == .assistant, newer.entry.role == .assistant,
               let messageId = entry.messageId, newer.entry.messageId == messageId,
               entry.blocks.count + newer.entry.blocks.count <= ClaudeTranscriptLimits.maxBlocksPerEntry {
                let merged = ClaudeTranscriptEntry(
                    id: entry.id, role: .assistant, timestamp: entry.timestamp ?? newer.entry.timestamp,
                    messageId: messageId, blocks: entry.blocks + newer.entry.blocks
                )
                let size = ClaudeTranscriptRenderer.encodedSize(merged) + 1
                if size <= ClaudeTranscriptRenderer.maxEntryBytes + 1, used - newer.size + size <= entryBytesBudget {
                    kept[kept.count - 1] = (merged, line.start, size)
                    used += size - newer.size
                    return true
                }
            }
            let size = ClaudeTranscriptRenderer.encodedSize(entry) + 1
            guard kept.count < maxEntries, used + size <= entryBytesBudget else { return false }
            kept.append((entry, line.start, size))
            used += size
            return true
        }

        let before: Int64?
        if scan.stoppedByCaller, let oldest = kept.last {
            before = oldest.start
        } else {
            before = scan.budgetBefore
        }
        return Page(
            entries: kept.reversed().map(\.entry),
            before: before.flatMap { $0 > 0 ? $0 : nil },
            scan: scan,
            brokenLines: broken
        )
    }

    private static func preadRetryingEINTR(_ descriptor: Int32, _ buffer: UnsafeMutablePointer<UInt8>, _ count: Int, _ offset: off_t) -> Int {
        var result: Int
        repeat { result = Darwin.pread(descriptor, buffer, count, offset) } while result < 0 && errno == EINTR
        return result
    }
}
