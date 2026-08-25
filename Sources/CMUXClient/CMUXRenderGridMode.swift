import Foundation

/// Retains a DEC or ANSI mode advertised by the daemon replay.
struct CMUXRenderGridMode: Decodable, Equatable, Sendable {
    let code: Int
    let ansi: Bool
    let on: Bool
}
