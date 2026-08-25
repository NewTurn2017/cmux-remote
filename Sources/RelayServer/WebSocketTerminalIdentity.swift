import Foundation

/// Identifies one surface subscription generation inside a WebSocket output lifecycle.
struct WebSocketTerminalIdentity: Hashable, Sendable {
    let surfaceId: String
    let streamIdentity: UUID
}
