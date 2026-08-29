struct TerminalArtifactCacheIndexEntry: Codable, Sendable {
    let digest: String
    let kind: TerminalArtifactCacheEntryKind
    let hostDigest: String
    let accountDigest: String
    let pathDigest: String
    let revisionDigest: String
    let dimension: Int?
    let bytes: Int
    var accessOrdinal: UInt64
}
