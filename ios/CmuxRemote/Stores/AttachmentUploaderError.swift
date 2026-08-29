enum AttachmentUploaderError: Error, Equatable {
    case invalidBeginResult
    case invalidChunkResult
    case invalidCommitResult
    case stagedFileChanged
}
