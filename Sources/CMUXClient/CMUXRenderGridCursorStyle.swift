import Foundation

/// Describes the daemon cursor shape, including legacy numeric values.
enum CMUXRenderGridCursorStyle: Equatable, Sendable {
    case block
    case bar
    case underline
    case blockHollow
    case legacy(Int)
}

extension CMUXRenderGridCursorStyle: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let legacy = try? container.decode(Int.self) {
            self = legacy == 0 ? .block : .legacy(legacy)
            return
        }

        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "block": self = .block
        case "bar": self = .bar
        case "underline": self = .underline
        case "block_hollow": self = .blockHollow
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown render-grid cursor style: \(rawValue)"
            )
        }
    }
}
