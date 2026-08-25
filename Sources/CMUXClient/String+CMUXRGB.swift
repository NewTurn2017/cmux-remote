import Foundation

extension String {
    /// Parses a daemon six-digit RGB value with an optional leading `#`.
    var cmuxRGBComponents: (red: Int, green: Int, blue: Int)? {
        let hex = hasPrefix("#") ? String(dropFirst()) : self
        guard hex.count == 6, let raw = Int(hex, radix: 16) else { return nil }
        return ((raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF)
    }

    /// Returns one lowercase representation for semantically identical daemon RGB values.
    var cmuxNormalizedRGB: String? {
        guard let components = cmuxRGBComponents else { return nil }
        return String(
            format: "#%02x%02x%02x",
            components.red,
            components.green,
            components.blue
        )
    }
}
