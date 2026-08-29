struct TerminalArtifactThumbnailCacheKey: Hashable, Sendable {
    let hostID: String
    let accountScope: String
    let pathToken: String
    let revision: String
    let dimension: Int
}
