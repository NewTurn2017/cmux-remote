struct TerminalArtifactCacheKey: Hashable, Sendable {
    let hostID: String
    let accountScope: String
    let pathToken: String
    let revision: String
}
