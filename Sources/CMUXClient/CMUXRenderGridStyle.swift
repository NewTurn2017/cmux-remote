import Foundation

/// Retains one daemon style and emits its supported effective visual attributes.
struct CMUXRenderGridStyle: Decodable, Equatable, Sendable {
    static let `default` = CMUXRenderGridStyle(id: 0)

    let id: Int
    let foreground: String?
    let background: String?
    let foregroundSource: CMUXRenderGridColorSource?
    let foregroundPaletteIndex: Int?
    let backgroundSource: CMUXRenderGridColorSource?
    let backgroundPaletteIndex: Int?
    let bold: Bool
    let faint: Bool
    let italic: Bool
    let underline: Bool
    let blink: Bool
    let inverse: Bool
    let invisible: Bool
    let strikethrough: Bool
    let overline: Bool

    init(
        id: Int,
        foreground: String? = nil,
        background: String? = nil,
        foregroundSource: CMUXRenderGridColorSource? = nil,
        foregroundPaletteIndex: Int? = nil,
        backgroundSource: CMUXRenderGridColorSource? = nil,
        backgroundPaletteIndex: Int? = nil,
        bold: Bool = false,
        faint: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        blink: Bool = false,
        inverse: Bool = false,
        invisible: Bool = false,
        strikethrough: Bool = false,
        overline: Bool = false
    ) {
        self.id = id
        self.foreground = foreground
        self.background = background
        self.foregroundSource = foregroundSource
        self.foregroundPaletteIndex = foregroundPaletteIndex
        self.backgroundSource = backgroundSource
        self.backgroundPaletteIndex = backgroundPaletteIndex
        self.bold = bold
        self.faint = faint
        self.italic = italic
        self.underline = underline
        self.blink = blink
        self.inverse = inverse
        self.invisible = invisible
        self.strikethrough = strikethrough
        self.overline = overline
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        foreground = try container.decodeIfPresent(String.self, forKey: .foreground)
        background = try container.decodeIfPresent(String.self, forKey: .background)
        foregroundSource = try container.decodeIfPresent(CMUXRenderGridColorSource.self, forKey: .foregroundSource)
        foregroundPaletteIndex = try container.decodeIfPresent(Int.self, forKey: .foregroundPaletteIndex)
        backgroundSource = try container.decodeIfPresent(CMUXRenderGridColorSource.self, forKey: .backgroundSource)
        backgroundPaletteIndex = try container.decodeIfPresent(Int.self, forKey: .backgroundPaletteIndex)
        bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        faint = try container.decodeIfPresent(Bool.self, forKey: .faint) ?? false
        italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        underline = try container.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        blink = try container.decodeIfPresent(Bool.self, forKey: .blink) ?? false
        inverse = try container.decodeIfPresent(Bool.self, forKey: .inverse) ?? false
        invisible = try container.decodeIfPresent(Bool.self, forKey: .invisible) ?? false
        strikethrough = try container.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
        overline = try container.decodeIfPresent(Bool.self, forKey: .overline) ?? false
    }

    func ansiSequence(
        defaultForeground: String,
        defaultBackground: String,
        previousBold: Bool,
        previousUnderline: Bool
    ) -> String {
        var resolvedForeground = color(
            value: foreground,
            source: foregroundSource,
            terminalDefault: defaultForeground
        )
        var resolvedBackground = color(
            value: background,
            source: backgroundSource,
            terminalDefault: defaultBackground
        )
        if inverse {
            swap(&resolvedForeground, &resolvedBackground)
        }

        let foregroundRGB = resolvedForeground.cmuxRGBComponents ?? (255, 255, 255)
        let backgroundRGB = resolvedBackground.cmuxRGBComponents ?? (0, 0, 0)
        var codes: [String] = []
        if previousBold && !bold { codes.append("22") }
        if previousUnderline && !underline { codes.append("24") }
        if !previousBold && bold { codes.append("1") }
        if !previousUnderline && underline { codes.append("4") }
        codes.append("38;2;\(foregroundRGB.red);\(foregroundRGB.green);\(foregroundRGB.blue)")
        codes.append("48;2;\(backgroundRGB.red);\(backgroundRGB.green);\(backgroundRGB.blue)")
        return "\u{1B}[\(codes.joined(separator: ";"))m"
    }

    private func color(
        value: String?,
        source: CMUXRenderGridColorSource?,
        terminalDefault: String
    ) -> String {
        if source == .defaultColor {
            return terminalDefault
        }
        guard let value, value.cmuxRGBComponents != nil else {
            return terminalDefault
        }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case foreground
        case background
        case foregroundSource
        case foregroundPaletteIndex
        case backgroundSource
        case backgroundPaletteIndex
        case bold
        case faint
        case italic
        case underline
        case blink
        case inverse
        case invisible
        case strikethrough
        case overline
    }
}
