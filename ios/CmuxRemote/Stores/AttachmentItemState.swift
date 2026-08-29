enum AttachmentItemState: Equatable, Sendable {
    case staging
    case ready
    case uploading(bytesSent: Int64)
    case succeeded(path: String, quotedPath: String)
    case failed(AttachmentItemFailure)
    case cancelled
    case unattempted
}
