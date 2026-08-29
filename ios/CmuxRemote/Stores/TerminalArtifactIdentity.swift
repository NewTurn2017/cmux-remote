struct TerminalArtifactIdentity: Equatable, Sendable {
    let hostID: String
    let accountScope: String
    let hostGeneration: Int
    let workspaceID: String
    let surfaceID: String
}
