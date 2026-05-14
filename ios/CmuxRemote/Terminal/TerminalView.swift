import SwiftUI

struct TerminalView: View {
    @Bindable var store: SurfaceStore
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0
    var scrollToBottomRequest: Int = 0
    var mouseMode: Bool = false
    var onMouseClick: ((Int, Int) -> Void)? = nil
    @State private var fontSize: CGFloat = 8
    @State private var pinchAnchorFontSize: CGFloat?

    private static let fontSizeRange: ClosedRange<CGFloat> = 8...32

    var body: some View {
        GeometryReader { proxy in
            let lineHeight = fontSize + 2
            let advance = fontSize * 0.6
            let leftInset: CGFloat = 16
            let topInset = max(0, topContentInset)
            let bottomInset = max(0, bottomContentInset)
            let viewportHeight = max(0, proxy.size.height - topInset - bottomInset)
            let viewportColumns = max(0, Int((proxy.size.width - leftInset) / advance) + 1)
            let contentColumns = max(
                viewportColumns,
                store.grid.cols,
                store.grid.cursor.x + 1,
                store.grid.rows.map { TerminalCellWidth.columns(for: $0) }.max() ?? 0
            )
            let contentWidth = max(proxy.size.width, leftInset + CGFloat(contentColumns) * advance + 24)
            let contentHeight = max(viewportHeight + 1, CGFloat(store.grid.rows.count) * lineHeight + 24)
            let visibleCols = contentColumns

            ZStack(alignment: .top) {
                CmuxTheme.terminal
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Color.clear.frame(height: topInset)

                    ScrollView(.horizontal, showsIndicators: false) {
                        ScrollViewReader { verticalScroll in
                            ScrollView(.vertical, showsIndicators: false) {
                                Canvas { context, _ in
                                    for (y, row) in store.grid.rows.enumerated() {
                                        var column = 0
                                        for cell in row {
                                            guard column < visibleCols else { break }
                                            let cellColumns = TerminalCellWidth.columns(for: cell.character)
                                            let drawColumn = cellColumns == 0 ? max(column - 1, 0) : column
                                            let point = CGPoint(
                                                x: leftInset + CGFloat(drawColumn) * advance,
                                                y: 8 + CGFloat(y) * lineHeight
                                            )
                                            context.draw(
                                                Text(TerminalGlyph.textStyleString(for: cell.character))
                                                    .font(CmuxFont.body(
                                                        fontSize,
                                                        weight: cell.attr.bold ? .bold : .regular
                                                    ))
                                                    .foregroundStyle(cell.attr.fg.swiftUI),
                                                at: point,
                                                anchor: .topLeading
                                            )
                                            column += cellColumns
                                        }
                                    }

                                    if store.grid.cursor.x < visibleCols {
                                        let cursorX = leftInset + CGFloat(store.grid.cursor.x) * advance
                                        let cursorY = 8 + CGFloat(store.grid.cursor.y) * lineHeight
                                        context.fill(
                                            Path(CGRect(x: cursorX, y: cursorY, width: advance, height: lineHeight)),
                                            with: .color(CmuxTheme.accentGreen.opacity(0.85))
                                        )
                                    }
                                }
                                .frame(width: contentWidth, height: contentHeight)
                                .contentShape(Rectangle())
                                .onTapGesture(coordinateSpace: .local) { location in
                                    guard mouseMode, let onMouseClick else { return }
                                    let col = Int(((location.x - leftInset) / advance).rounded(.down))
                                    let row = Int(((location.y - 8) / lineHeight).rounded(.down))
                                    let clampedCol = max(0, min(col, store.grid.cols - 1))
                                    let clampedRow = max(0, min(row, store.grid.rows.count - 1))
                                    onMouseClick(clampedCol, clampedRow)
                                }
                                .cmuxScanlines()

                                Color.clear
                                    .frame(width: contentWidth, height: 1)
                                    .id(TerminalScrollTarget.bottom)
                            }
                            .frame(width: contentWidth, height: viewportHeight)
                            .scrollClipDisabled(false)
                            .accessibilityIdentifier("TerminalViewport")
                            .accessibilityLabel("Terminal output")
                            .accessibilityValue(accessibilitySnapshot)
                            .onChange(of: scrollToBottomRequest) { _, _ in
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                    verticalScroll.scrollTo(TerminalScrollTarget.bottom, anchor: .bottom)
                                }
                            }
                        }
                    }
                    .frame(width: proxy.size.width, height: viewportHeight)
                    .scrollClipDisabled(false)

                    Color.clear.frame(height: bottomInset)
                }
            }
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.005)
                    .onChanged { value in
                        if pinchAnchorFontSize == nil { pinchAnchorFontSize = fontSize }
                        let base = pinchAnchorFontSize ?? fontSize
                        fontSize = Self.fontSizeRange.clamping(base * value.magnification)
                    }
                    .onEnded { value in
                        let base = pinchAnchorFontSize ?? fontSize
                        fontSize = Self.fontSizeRange.clamping(base * value.magnification)
                        pinchAnchorFontSize = nil
                    }
            )
        }
        .background(CmuxTheme.terminal)
    }

    private var accessibilitySnapshot: String {
        store.grid.rows
            .prefix(6)
            .map { row in row.map { String($0.character) }.joined().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

private enum TerminalScrollTarget {
    static let bottom = "terminal-bottom"
}

private extension ClosedRange where Bound == CGFloat {
    func clamping(_ value: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}

/// iOS auto-promotes Unicode chars that have a default emoji presentation
/// (●, ✔, ☂, ⚠, ▶ …) to the system Apple Color Emoji font when our
/// monospace font lacks the glyph — which renders them as comically large
/// color emoji in the terminal grid. Variation Selector-15 (U+FE0E) tells
/// the renderer to keep the text-style glyph instead. We only append it
/// for scalars in the symbol/dingbat/geometric-shape ranges so ASCII and
/// CJK paths stay zero-overhead.
enum TerminalGlyph {
    static func textStyleString(for character: Character) -> String {
        if let substitute = substitutions[character] {
            return substitute
        }
        let s = String(character)
        guard let scalar = s.unicodeScalars.first, mayPromoteToEmoji(scalar) else {
            return s
        }
        return s + "\u{FE0E}"
    }

    /// Hard substitutions for chars Unicode flags as default-emoji-presentation
    /// where iOS has no text-style fallback glyph — VS-15 alone leaves them
    /// as full-color emoji. Map to a visually-equivalent text glyph plus
    /// VS-15 to keep the layout text-styled.
    private static let substitutions: [Character: String] = [
        "\u{23FA}": "\u{25CF}\u{FE0E}", // ⏺ Record → ●
        "\u{23F8}": "\u{2016}",          // ⏸ Pause → ‖
        "\u{23F9}": "\u{25A0}\u{FE0E}", // ⏹ Stop → ■
        "\u{23EB}": "\u{2191}",          // ⏫ Fast Up → ↑
        "\u{23EC}": "\u{2193}",          // ⏬ Fast Down → ↓
        "\u{23ED}": "\u{226B}",          // ⏭ Next → ≫
        "\u{23EE}": "\u{226A}",          // ⏮ Prev → ≪
        "\u{23EF}": "\u{25B6}\u{FE0E}", // ⏯ Play/Pause → ▶
    ]

    private static func mayPromoteToEmoji(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // Geometric Shapes (●○■□▲▼…), Misc Symbols (☀☁☂…), Dingbats (✔✖✦…),
        // Misc Symbols & Pictographs lower band, plus the few stragglers that
        // iOS color-promotes from the BMP punctuation blocks.
        return (0x2190...0x21FF).contains(v) // Arrows
            || (0x2300...0x23FF).contains(v) // Misc Technical (⌘ ⏎ …)
            || (0x2460...0x24FF).contains(v) // Enclosed Alphanumerics
            || (0x25A0...0x25FF).contains(v) // Geometric Shapes
            || (0x2600...0x26FF).contains(v) // Misc Symbols
            || (0x2700...0x27BF).contains(v) // Dingbats
            || (0x2B00...0x2BFF).contains(v) // Misc Symbols and Arrows
            || (0x1F300...0x1F5FF).contains(v) // Misc Symbols & Pictographs
            || (0x1F600...0x1F64F).contains(v) // Emoticons
            || (0x1F680...0x1F6FF).contains(v) // Transport & Map
    }
}

private extension ANSIColor {
    // Tokyo Night Storm ANSI mapping — see github.com/folke/tokyonight.nvim.
    var swiftUI: Color {
        switch self {
        case .default: return CmuxTheme.terminalText
        case .red:     return CmuxTheme.accentRed
        case .green:   return CmuxTheme.accentGreen
        case .yellow:  return CmuxTheme.accentYellow
        case .blue:    return CmuxTheme.accentBlue
        case .magenta: return CmuxTheme.accentMagenta
        case .cyan:    return CmuxTheme.accentCyan
        case .white:   return CmuxTheme.terminalText
        case .black:   return CmuxTheme.mutedDim
        case .bright(let inner): return inner.swiftUI
        }
    }
}
