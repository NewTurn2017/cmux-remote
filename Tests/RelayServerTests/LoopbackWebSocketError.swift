/// Bounded loopback WebSocket driver failures.
enum LoopbackWebSocketError: Error {
    case invalidUpgrade
    case invalidFrame
    case closed
    case timeout
}
