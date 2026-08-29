struct AttachmentItemFailure: Equatable, Sendable {
    let code: String
    let message: String
    let retryable: Bool
}
