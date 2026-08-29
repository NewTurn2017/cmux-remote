/// Stores one encoded outbound payload and all separately retained encoded recovery bytes.
///
/// Terminal entries conservatively count both `text` and their encoded recovery string,
/// even when the values are equal and Swift may share COW storage. The frame-count bound
/// covers fixed entry overhead; ``retainedFramedByteCount`` bounds encoded buffers.
struct WebSocketQueuedOutput: Sendable {
    let text: String
    let retainedFramedByteCount: Int
    let kind: WebSocketOutputKind

    init(text: String, kind: WebSocketOutputKind) throws {
        self.text = text
        self.kind = kind
        let currentBytes = try WebSocketFramedSize(text: text).totalBytes
        let recoveryBytes: Int
        switch kind {
        case .critical:
            recoveryBytes = 0
        case .screen(_, _, _, let recoveryText, _):
            recoveryBytes = try WebSocketFramedSize(text: recoveryText).totalBytes
        }
        let (retainedBytes, overflow) = currentBytes.addingReportingOverflow(recoveryBytes)
        guard !overflow else {
            throw WebSocketFramedSizeError.overflow
        }
        self.retainedFramedByteCount = retainedBytes
    }
}
