import Foundation

/// Fixed bounds of the `claude.sessions.list` and `claude.transcript.page` contract.
public enum ClaudeTranscriptLimits {
    /// Sessions returned when `claude.sessions.list` has no `limit`.
    public static let defaultSessionLimit = 50
    /// Largest accepted `limit` for `claude.sessions.list`.
    public static let maxSessionLimit = 100
    /// Longest accepted session id, in characters.
    public static let maxSessionIdCharacters = 128
    /// Longest session title, in characters.
    public static let maxSessionTitleCharacters = 512
    /// Longest session working directory, in characters.
    public static let maxCwdCharacters = 1_024
    /// Longest git branch name, in characters.
    public static let maxGitBranchCharacters = 256
    /// Longest session status word, in characters.
    public static let maxStatusCharacters = 32
    /// Entries returned when `claude.transcript.page` has no `max_entries`.
    public static let defaultPageEntries = 40
    /// Largest accepted `max_entries`.
    public static let maxPageEntries = 100
    /// Most blocks in one entry.
    public static let maxBlocksPerEntry = 32
    /// Largest text block, in UTF-8 bytes.
    public static let maxTextBytes = 16 * 1_024
    /// Longest tool name, in characters.
    public static let maxToolNameCharacters = 128
    /// Longest tool-call summary, in characters.
    public static let maxToolUseSummaryCharacters = 512
    /// Largest tool-result summary, in UTF-8 bytes.
    public static let maxToolResultSummaryBytes = 2 * 1_024
    /// Transcript lines longer than this are skipped without being held in memory.
    public static let maxLineBytes = 4 * 1_024 * 1_024
    /// Most transcript bytes the relay reads for one page request.
    public static let maxScanBytesPerRequest = 16 * 1_024 * 1_024
    /// Size of one backward read from the transcript file.
    public static let readBlockBytes = 256 * 1_024
    /// Largest encoded response, so one frame stays under 1 MiB.
    public static let maxResponseBytes = 737_280
    /// Bytes kept free inside ``maxResponseBytes`` for the RPC envelope.
    public static let responseEnvelopeReserveBytes = 8 * 1_024

    /// Whether `value` is a session id the relay may look up: 1 to 128 of `A-Z a-z 0-9 . _ -`, not `.` or `..`.
    public static func isValidSessionId(_ value: String) -> Bool {
        guard (1...maxSessionIdCharacters).contains(value.count), value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-": return true
            default: return false
            }
        }
    }
}

extension KeyedDecodingContainer {
    func contractSessionId(_ key: Key, field: String) throws -> String {
        let value = try contractText(key, field: field)
        guard ClaudeTranscriptLimits.isValidSessionId(value) else { throw RemoteProtocolError.invalidField(field) }
        return value
    }
}
