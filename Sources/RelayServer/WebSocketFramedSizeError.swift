/// Reports an invalid or overflowing WebSocket frame-size calculation.
enum WebSocketFramedSizeError: Error {
    case negativePayloadLength
    case overflow
}
