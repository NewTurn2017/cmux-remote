struct AttachmentItem: Identifiable, Equatable, Sendable {
    var id: Int { ordinal }
    let ordinal: Int
    var filename: String
    var bytes: Int64?
    var state: AttachmentItemState

    var failure: AttachmentItemFailure? {
        guard case .failed(let failure) = state else { return nil }
        return failure
    }

    var isSucceeded: Bool {
        if case .succeeded = state { return true }
        return false
    }

    var isCancelled: Bool {
        state == .cancelled || state == .unattempted
    }
}
