import Foundation

/// Identifies one lifetime of a render-grid producer.
struct CMUXRenderEpoch: Decodable, Equatable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
}
