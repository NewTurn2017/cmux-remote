import Foundation

/// Identifies whether row indexes address the viewport or active screen.
enum CMUXRenderGridAnchor: String, Decodable, Equatable, Sendable {
    case viewport
    case screen
}
