import Foundation

/// Preserves whether a daemon color originated from defaults, a palette, or RGB.
enum CMUXRenderGridColorSource: String, Decodable, Equatable, Sendable {
    case defaultColor = "default"
    case palette
    case rgb
}
