import Foundation

/// Carries the monotonic capture revision within a render epoch.
struct CMUXRenderRevision: Decodable, Equatable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt64.self)
    }
}
