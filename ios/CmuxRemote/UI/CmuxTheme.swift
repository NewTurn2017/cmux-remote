import Foundation
import SwiftUI

// MARK: - Tokyo Night Storm palette (with terminal-aesthetic extensions)
// Source: github.com/folke/tokyonight.nvim — palette/colors/storm.lua

enum CmuxColorTheme: String, CaseIterable, Identifiable {
    case storm, ocean, graphite

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .storm: return "Tokyo Night"
        case .ocean: return "Ocean"
        case .graphite: return "Graphite"
        }
    }
}

enum CmuxTheme {
    private struct Palette {
        let canvas: Color
        let surface: Color
        let surfaceRaised: Color
        let surfaceSunken: Color
        let terminal: Color
        let ink: Color
        let inkDim: Color
        let muted: Color
        let mutedDim: Color
        let divider: Color
        let border: Color
        let accentBlue: Color
        let accentCyan: Color
        let accentTeal: Color
        let accentGreen: Color
        let accentYellow: Color
        let accentOrange: Color
        let accentRed: Color
        let accentMagenta: Color
        let accentPurple: Color
        let terminalText: Color
    }

    /// Resolve from the persisted preference on every SwiftUI update.  This
    /// deliberately avoids a mutable global palette: otherwise a Picker can
    /// write a new theme without invalidating views that already read colors.
    private static var activePalette: Palette { palette(for: storedTheme) }

    static func apply(themeRawValue: String) {
        // Kept as the single integration point for callers. `activePalette`
        // reads the same persisted value reactively when SwiftUI redraws.
    }

    static func previewColor(for theme: CmuxColorTheme) -> Color {
        palette(for: theme).accentBlue
    }

    static var canvas: Color { activePalette.canvas }
    static var surface: Color { activePalette.surface }
    static var surfaceRaised: Color { activePalette.surfaceRaised }
    static var surfaceSunken: Color { activePalette.surfaceSunken }
    static var terminal: Color { activePalette.terminal }
    static var ink: Color { activePalette.ink }
    static var inkDim: Color { activePalette.inkDim }
    static var muted: Color { activePalette.muted }
    static var mutedDim: Color { activePalette.mutedDim }
    static var divider: Color { activePalette.divider }
    static var border: Color { activePalette.border }
    static var accentBlue: Color { activePalette.accentBlue }
    static var accentCyan: Color { activePalette.accentCyan }
    static var accentTeal: Color { activePalette.accentTeal }
    static var accentGreen: Color { activePalette.accentGreen }
    static var accentYellow: Color { activePalette.accentYellow }
    static var accentOrange: Color { activePalette.accentOrange }
    static var accentRed: Color { activePalette.accentRed }
    static var accentMagenta: Color { activePalette.accentMagenta }
    static var accentPurple: Color { activePalette.accentPurple }
    static var terminalText: Color { activePalette.terminalText }

    // Legacy aliases used by older view code.
    static var card: Color { surface }
    static var glass: Color { surface.opacity(0.92) }
    static var selectedGlass: Color { surfaceRaised }
    static var terminalPanel: Color { surfaceSunken }
    static var terminalChip: Color { surfaceRaised }
    static var terminalMuted: Color { muted }
    static var terminalAccent: Color { accentGreen }
    static var danger: Color { accentRed }

    static let softShadow = Color.black.opacity(0.45)
    static let hardShadow = Color.black.opacity(0.7)

    private static var storedTheme: CmuxColorTheme {
        CmuxColorTheme(rawValue: UserDefaults.standard.string(forKey: "cmux.theme") ?? "") ?? .storm
    }

    private static func palette(for theme: CmuxColorTheme) -> Palette {
        switch theme {
        case .storm:
            return Palette(
                canvas: hex(0x1A1B26), surface: hex(0x24283B), surfaceRaised: hex(0x292E42),
                surfaceSunken: hex(0x1F2335), terminal: hex(0x16161E), ink: hex(0xC0CAF5),
                inkDim: hex(0xA9B1D6), muted: hex(0x565F89), mutedDim: hex(0x414868),
                divider: hex(0x3B4261), border: hex(0x545C7E), accentBlue: hex(0x7AA2F7),
                accentCyan: hex(0x7DCFFF), accentTeal: hex(0x1ABC9C), accentGreen: hex(0x9ECE6A),
                accentYellow: hex(0xE0AF68), accentOrange: hex(0xFF9E64), accentRed: hex(0xF7768E),
                accentMagenta: hex(0xBB9AF7), accentPurple: hex(0x9D7CD8), terminalText: hex(0xF1F2F8)
            )
        case .ocean:
            return Palette(
                canvas: hex(0x0B1724), surface: hex(0x102538), surfaceRaised: hex(0x143047),
                surfaceSunken: hex(0x0E2032), terminal: hex(0x07131F), ink: hex(0xD6EDFF),
                inkDim: hex(0xA8C5DB), muted: hex(0x5F829E), mutedDim: hex(0x34536B),
                divider: hex(0x28445E), border: hex(0x41647E), accentBlue: hex(0x60A5FA),
                accentCyan: hex(0x67E8F9), accentTeal: hex(0x2DD4BF), accentGreen: hex(0x86EFAC),
                accentYellow: hex(0xFCD34D), accentOrange: hex(0xFDBA74), accentRed: hex(0xFB7185),
                accentMagenta: hex(0xF0ABFC), accentPurple: hex(0xC4B5FD), terminalText: hex(0xF4FAFF)
            )
        case .graphite:
            return Palette(
                canvas: hex(0x171717), surface: hex(0x242424), surfaceRaised: hex(0x303030),
                surfaceSunken: hex(0x1E1E1E), terminal: hex(0x101010), ink: hex(0xF5F5F5),
                inkDim: hex(0xD4D4D4), muted: hex(0x8A8A8A), mutedDim: hex(0x525252),
                divider: hex(0x454545), border: hex(0x666666), accentBlue: hex(0xA3E635),
                accentCyan: hex(0x67E8F9), accentTeal: hex(0x5EEAD4), accentGreen: hex(0xBEF264),
                accentYellow: hex(0xFDE047), accentOrange: hex(0xFDBA74), accentRed: hex(0xFDA4AF),
                accentMagenta: hex(0xF5D0FE), accentPurple: hex(0xDDD6FE), terminalText: hex(0xFAFAFA)
            )
        }
    }
}

// MARK: - Hex helper

private func hex(_ rgb: UInt32, alpha: Double = 1) -> Color {
    let r = Double((rgb >> 16) & 0xFF) / 255.0
    let g = Double((rgb >> 8) & 0xFF) / 255.0
    let b = Double(rgb & 0xFF) / 255.0
    return Color(.sRGB, red: r, green: g, blue: b, opacity: alpha)
}

// MARK: - Fonts
// Display = Departure Mono (pixel, headers / labels / chips).
// Body    = Geist Mono (clean monospace, readable body / terminals).
// Falls back gracefully to system .monospaced if the bundled font isn't loaded.

enum CmuxFont {
    static func display(_ size: CGFloat) -> Font {
        // 11pt grid recommended by Departure Mono author for pixel-perfect rendering.
        .custom("DepartureMono-Regular", size: size, relativeTo: .body)
    }

    static func body(_ size: CGFloat, weight: Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold:   name = "GeistMono-Bold"
        case .medium: name = "GeistMono-Medium"
        case .regular: name = "GeistMono-Regular"
        }
        return .custom(name, size: size, relativeTo: .body)
    }

    enum Weight { case regular, medium, bold }
}

extension View {
    /// Display label — pixel font, used for chips, section headers, key caps.
    func cmuxDisplay(_ size: CGFloat = 11) -> some View {
        font(CmuxFont.display(size))
            .tracking(0.4)
    }

    /// Body monospace — Geist Mono.
    func cmuxMono(_ size: CGFloat = 13, weight: CmuxFont.Weight = .regular) -> some View {
        font(CmuxFont.body(size, weight: weight))
    }
}

// MARK: - Surface styling

extension View {
    /// Old API kept for compatibility — now produces a dark hairline-bordered card.
    func cmuxCard() -> some View {
        modifier(CmuxCardModifier())
    }

    /// Adds an ASCII-style 1px border in Tokyo Night divider colour.
    func cmuxHairline(_ color: Color = CmuxTheme.divider, corner: CGFloat = 12) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(color, lineWidth: 1)
        )
    }
}

private struct CmuxCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(CmuxTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(CmuxTheme.divider, lineWidth: 1)
            )
            .shadow(color: CmuxTheme.softShadow, radius: 18, x: 0, y: 10)
    }
}

// MARK: - ASCII box-drawing rules

/// Horizontal rule made of box-drawing glyphs, e.g. `══ CMUX ══`.
struct CmuxRule: View {
    var title: String? = nil
    var glyph: Character = "═"
    var color: Color = CmuxTheme.divider

    var body: some View {
        HStack(spacing: 8) {
            ruleSegment
            if let title {
                Text(title.uppercased())
                    .cmuxDisplay(11)
                    .foregroundStyle(CmuxTheme.muted)
                    .fixedSize(horizontal: true, vertical: false)
            }
            ruleSegment
        }
    }

    private var ruleSegment: some View {
        GeometryReader { proxy in
            Text(String(repeating: String(glyph), count: max(1, Int(proxy.size.width / 7))))
                .cmuxDisplay(11)
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 14)
    }
}

// MARK: - Pixel chip (key-cap look)

struct CmuxChip<Label: View>: View {
    var tint: Color = CmuxTheme.surfaceRaised
    var border: Color = CmuxTheme.divider
    var foreground: Color = CmuxTheme.ink
    var pressed: Bool = false
    @ViewBuilder var label: () -> Label

    var body: some View {
        label()
            .cmuxDisplay(11)
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(pressed ? CmuxTheme.surfaceSunken : tint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
    }
}

// MARK: - Scanline shader application

extension View {
    /// Applies a CRT scanline + subtle RGB shift to the layer. Intended for the
    /// terminal mirror viewport only — applying globally hurts iOS legibility.
    @ViewBuilder
    func cmuxScanlines(lineHeight: Float = 2.5, intensity: Float = 0.18, shift: Float = 0.4) -> some View {
        if #available(iOS 17.0, *) {
            visualEffect { content, _ in
                content.layerEffect(
                    ShaderLibrary.cmuxScanlines(
                        .float(lineHeight),
                        .float(intensity),
                        .float(shift)
                    ),
                    maxSampleOffset: CGSize(width: CGFloat(shift), height: 0)
                )
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func cmuxScanlines(enabled: Bool, lineHeight: Float = 2.5, intensity: Float = 0.18, shift: Float = 0.4) -> some View {
        if enabled {
            cmuxScanlines(lineHeight: lineHeight, intensity: intensity, shift: shift)
        } else {
            self
        }
    }
}
