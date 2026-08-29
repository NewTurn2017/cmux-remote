import Foundation

/// Retains the terminal theme metadata included in a full replay frame.
struct CMUXTerminalTheme: Decodable, Equatable, Sendable {
    let name: String?
    let background: String?
    let foreground: String?
    let boldColor: String?
    let cursor: String?
    let cursorColorSemantic: String?
    let cursorText: String?
    let cursorTextSemantic: String?
    let selectionBackground: String?
    let selectionBackgroundSemantic: String?
    let selectionForeground: String?
    let selectionForegroundSemantic: String?
    let palette: [String]

    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.name = name
            background = nil
            foreground = nil
            boldColor = nil
            cursor = nil
            cursorColorSemantic = nil
            cursorText = nil
            cursorTextSemantic = nil
            selectionBackground = nil
            selectionBackgroundSemantic = nil
            selectionForeground = nil
            selectionForegroundSemantic = nil
            palette = []
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = nil
        background = try container.decodeIfPresent(String.self, forKey: .background)
        foreground = try container.decodeIfPresent(String.self, forKey: .foreground)
        boldColor = try container.decodeIfPresent(String.self, forKey: .boldColor)
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
        cursorColorSemantic = try container.decodeIfPresent(String.self, forKey: .cursorColorSemantic)
        cursorText = try container.decodeIfPresent(String.self, forKey: .cursorText)
        cursorTextSemantic = try container.decodeIfPresent(String.self, forKey: .cursorTextSemantic)
        selectionBackground = try container.decodeIfPresent(String.self, forKey: .selectionBackground)
        selectionBackgroundSemantic = try container.decodeIfPresent(String.self, forKey: .selectionBackgroundSemantic)
        selectionForeground = try container.decodeIfPresent(String.self, forKey: .selectionForeground)
        selectionForegroundSemantic = try container.decodeIfPresent(String.self, forKey: .selectionForegroundSemantic)
        palette = try container.decodeIfPresent([String].self, forKey: .palette) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case background
        case foreground
        case boldColor
        case cursor
        case cursorColorSemantic
        case cursorText
        case cursorTextSemantic
        case selectionBackground
        case selectionBackgroundSemantic
        case selectionForeground
        case selectionForegroundSemantic
        case palette
    }
}
