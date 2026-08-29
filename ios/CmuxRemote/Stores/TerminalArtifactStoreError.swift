enum TerminalArtifactStoreError: Error, Equatable {
    case inactive
    case staleIdentity
    case artifactChanged
    case malformedChunk
    case malformedThumbnail
    case imageTooLarge
    case tooManyPixels
    case notAnImage
}
