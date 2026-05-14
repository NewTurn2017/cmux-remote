import SwiftUI

// MARK: - Tokyo Night Storm palette (with terminal-aesthetic extensions)
// Source: github.com/folke/tokyonight.nvim — palette/colors/storm.lua

enum CmuxTheme {
    // Base surfaces
    static let canvas       = hex(0x1A1B26)   // app background (Night-darker than storm bg)
    static let surface      = hex(0x24283B)   // primary card / panel
    static let surfaceRaised = hex(0x292E42)  // hover/selected
    static let surfaceSunken = hex(0x1F2335)  // inset panels
    static let terminal     = hex(0x16161E)   // terminal viewport — deepest

    // Text
    static let ink          = hex(0xC0CAF5)   // primary fg
    static let inkDim       = hex(0xA9B1D6)   // secondary fg
    static let muted        = hex(0x565F89)   // comment grey
    static let mutedDim     = hex(0x414868)   // terminal-black, for separators

    // Hairlines & borders
    static let divider      = hex(0x3B4261)   // fg_gutter
    static let border       = hex(0x545C7E)   // dark3

    // Accents
    static let accentBlue   = hex(0x7AA2F7)   // primary action
    static let accentCyan   = hex(0x7DCFFF)
    static let accentTeal   = hex(0x1ABC9C)
    static let accentGreen  = hex(0x9ECE6A)   // success / online
    static let accentYellow = hex(0xE0AF68)
    static let accentOrange = hex(0xFF9E64)
    static let accentRed    = hex(0xF7768E)   // error / danger
    static let accentMagenta = hex(0xBB9AF7)
    static let accentPurple = hex(0x9D7CD8)

    // Terminal viewport text — a near-white tone so unstyled output reads as
    // body text instead of borrowing the lavender cast of `ink`. ANSI accents
    // still override per-cell, so red/blue/yellow remain visible.
    static let terminalText     = hex(0xF1F2F8)

    // Legacy aliases used by older view code
    static let card             = surface
    static let glass            = surface.opacity(0.92)
    static let selectedGlass    = surfaceRaised
    static let terminalPanel    = surfaceSunken
    static let terminalChip     = surfaceRaised
    static let terminalMuted    = muted
    static let terminalAccent   = accentGreen
    static let danger           = accentRed

    static let softShadow = Color.black.opacity(0.45)
    static let hardShadow = Color.black.opacity(0.7)
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
}
