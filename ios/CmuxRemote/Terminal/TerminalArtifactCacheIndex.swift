import Foundation

struct TerminalArtifactCacheIndex: Codable, Sendable {
    var accessOrdinal: UInt64
    var entries: [String: TerminalArtifactCacheIndexEntry]

    static let empty = TerminalArtifactCacheIndex(accessOrdinal: 0, entries: [:])
}
