import Foundation

struct ScriptedTerminalReadEvent: Equatable, Sendable {
    let workspaceId: String
    let surfaceId: String
    let readCount: Int
    let inFlight: Int
}
