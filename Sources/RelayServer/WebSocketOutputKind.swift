import Foundation

/// Classifies a queued WebSocket payload as ordered critical output or coalescible screen state.
enum WebSocketOutputKind: Sendable {
    case critical
    case screen(
        surfaceId: String,
        streamIdentity: UUID,
        revision: Int,
        recoveryText: String,
        frameKind: WebSocketOutputFrameKind
    )
}
