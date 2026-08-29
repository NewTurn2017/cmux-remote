import Foundation

/// Captures the render-grid cursor without projecting it into relay behavior yet.
struct CMUXRenderGridCursor: Decodable, Equatable, Sendable {
    let row: Int
    let column: Int
    let visible: Bool
    let blinking: Bool
    let style: CMUXRenderGridCursorStyle

    init(
        row: Int,
        column: Int,
        visible: Bool = true,
        blinking: Bool = false,
        style: CMUXRenderGridCursorStyle = .block
    ) {
        self.row = row
        self.column = column
        self.visible = visible
        self.blinking = blinking
        self.style = style
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        row = try container.decode(Int.self, forKey: .row)
        column = try container.decode(Int.self, forKey: .column)
        visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        blinking = try container.decodeIfPresent(Bool.self, forKey: .blinking) ?? false
        style = try container.decodeIfPresent(CMUXRenderGridCursorStyle.self, forKey: .style) ?? .block
    }

    private enum CodingKeys: String, CodingKey {
        case row
        case column
        case visible
        case blinking
        case style
    }
}
