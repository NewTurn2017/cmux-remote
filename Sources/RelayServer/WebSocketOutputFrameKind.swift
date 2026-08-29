/// Identifies output kinds for pump behavior and observability.
enum WebSocketOutputFrameKind: Sendable {
    case critical
    case full
    case diff
    case checksum
}
