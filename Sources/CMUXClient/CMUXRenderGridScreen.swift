import Foundation

/// Identifies the terminal screen represented by the replay.
enum CMUXRenderGridScreen: String, Decodable, Equatable, Sendable {
    case primary
    case alternate
}
