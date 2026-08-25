import Foundation

/// Decodes the daemon `terminal.replay` response envelope.
struct CMUXTerminalReplayRaw: Decodable, Equatable, Sendable {
    let columns: Int
    let rows: Int
    let sequence: UInt64
    let surfaceID: String
    let workspaceID: String
    let renderGrid: CMUXRenderGrid

    private enum CodingKeys: String, CodingKey {
        case columns
        case rows
        case sequence = "seq"
        case surfaceID = "surfaceId"
        case workspaceID = "workspaceId"
        case renderGrid
    }
}
