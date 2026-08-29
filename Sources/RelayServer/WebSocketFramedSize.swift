/// Represents the exact byte count of one unmasked server WebSocket frame.
struct WebSocketFramedSize: Equatable, Sendable {
    let payloadBytes: Int
    let totalBytes: Int

    init(payloadBytes: Int) throws {
        guard payloadBytes >= 0 else {
            throw WebSocketFramedSizeError.negativePayloadLength
        }
        let headerBytes: Int
        switch payloadBytes {
        case 0...125:
            headerBytes = 2
        case 126...65_535:
            headerBytes = 4
        default:
            headerBytes = 10
        }
        let (totalBytes, overflow) = payloadBytes.addingReportingOverflow(headerBytes)
        guard !overflow else {
            throw WebSocketFramedSizeError.overflow
        }
        self.payloadBytes = payloadBytes
        self.totalBytes = totalBytes
    }

    init(text: String) throws {
        try self.init(payloadBytes: text.utf8.count)
    }
}
