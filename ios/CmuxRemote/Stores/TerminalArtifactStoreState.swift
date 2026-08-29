enum TerminalArtifactStoreState: Equatable {
    case idle
    case loading
    case ready
    case unavailable
    case failed(String)
}
