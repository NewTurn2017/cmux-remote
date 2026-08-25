import SwiftUI

enum TerminalLayoutPolicy {
    static func defaultFontSize(isPad: Bool) -> CGFloat {
        isPad ? 11 : 8
    }
}

struct TerminalView: View {
    static let bottomScrollPaddingRows: CGFloat = 5

    @Bindable var store: SurfaceStore
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0
    var scrollToBottomRequest: Int = 0
    @State private var fontMetrics = TerminalFontMetrics(
        fontSize: TerminalLayoutPolicy.defaultFontSize(
            isPad: UIDevice.current.userInterfaceIdiom == .pad
        )
    )
    @State private var pinchAnchorFontSize: CGFloat?
    @State private var selectionController: TerminalSelectionController

    private static let fontSizeRange: ClosedRange<CGFloat> = 8...32

    @MainActor
    init(
        store: SurfaceStore,
        topContentInset: CGFloat = 0,
        bottomContentInset: CGFloat = 0,
        scrollToBottomRequest: Int = 0,
        selectionController: TerminalSelectionController? = nil
    ) {
        self.store = store
        self.topContentInset = topContentInset
        self.bottomContentInset = bottomContentInset
        self.scrollToBottomRequest = scrollToBottomRequest
        _selectionController = State(
            initialValue: selectionController ?? TerminalSelectionController()
        )
    }

    private var bottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    var body: some View {
        GeometryReader { proxy in
            let cellWidth = fontMetrics.cellWidth
            let lineHeight = fontMetrics.lineHeight
            let layout = TerminalGridLayout(cellWidth: cellWidth, lineHeight: lineHeight)
            let geometry = TerminalGridGeometry(cellWidth: cellWidth, lineHeight: lineHeight)
            let selectionSnapshot = TerminalSelectionSnapshot(renderRows: store.grid.renderRows)
            let bottomScrollPadding = Self.bottomScrollPadding(lineHeight: lineHeight)
            let leftInset: CGFloat = 16
            let topInset = max(0, topContentInset)
            let bottomInset = max(0, bottomContentInset)
            let viewportHeight = max(0, proxy.size.height - topInset - bottomInset)
            let viewportColumns = max(0, Int((proxy.size.width - leftInset) / cellWidth) + 1)
            let contentColumns = max(
                viewportColumns,
                store.grid.cols,
                store.grid.cursor.x + 1,
                store.grid.maxRenderedColumns
            )
            let contentWidth = max(proxy.size.width, leftInset + CGFloat(contentColumns) * cellWidth + 24)
            let contentHeight = max(viewportHeight + 1, CGFloat(store.grid.renderRows.count) * lineHeight + 24)
            let visibleCols = contentColumns
            let visibleRows = store.grid.renderRows.count

            ZStack(alignment: .top) {
                CmuxTheme.terminal
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Color.clear.frame(height: topInset)

                    ScrollView(.horizontal, showsIndicators: false) {
                        ScrollViewReader { verticalScroll in
                            ScrollView(.vertical, showsIndicators: false) {
                                Canvas { context, _ in
                                    for (y, row) in store.grid.renderRows.enumerated() {
                                        for run in row.runs where run.startColumn < visibleCols {
                                            guard run.attr.bg != .default, run.columns > 0 else { continue }
                                            let frame = layout.frame(
                                                startColumn: run.startColumn,
                                                columns: run.columns,
                                                row: y
                                            ).offsetBy(dx: leftInset, dy: 8)
                                            context.fill(Path(frame), with: .color(run.attr.bg.swiftUI))
                                        }
                                    }

                                    if let selection = selectionController.selection {
                                        for frame in TerminalSelectionOverlayGeometry.frames(
                                            for: selection,
                                            layout: layout
                                        ) {
                                            context.fill(
                                                Path(frame),
                                                with: .color(CmuxTheme.terminalSelectionFill)
                                            )
                                            context.stroke(
                                                Path(frame.insetBy(dx: 0.5, dy: 0.5)),
                                                with: .color(CmuxTheme.terminalSelectionOutline),
                                                lineWidth: 1
                                            )
                                        }
                                    }

                                    for (y, row) in store.grid.renderRows.enumerated() {
                                        for run in row.runs where run.startColumn < visibleCols {
                                            let frame = layout.frame(
                                                startColumn: run.startColumn,
                                                columns: run.columns,
                                                row: y
                                            ).offsetBy(dx: leftInset, dy: 8)
                                            var runContext = context
                                            runContext.clip(to: Path(frame))
                                            runContext.draw(
                                                Text(run.text)
                                                    .font(fontMetrics.font(bold: run.attr.bold))
                                                    .foregroundStyle(run.attr.fg.swiftUI),
                                                at: frame.origin,
                                                anchor: .topLeading
                                            )
                                            if run.attr.underline, run.columns > 0 {
                                                context.fill(
                                                    Path(CGRect(
                                                        x: frame.minX,
                                                        y: frame.maxY - 2,
                                                        width: frame.width,
                                                        height: max(1, fontMetrics.fontSize / 12)
                                                    )),
                                                    with: .color(run.attr.fg.swiftUI)
                                                )
                                            }
                                        }
                                    }

                                    if store.grid.cursor.isRenderable(
                                        columns: visibleCols,
                                        rows: visibleRows
                                    ) {
                                        let cursorX = leftInset + CGFloat(store.grid.cursor.x) * cellWidth
                                        let cursorY = 8 + CGFloat(store.grid.cursor.y) * lineHeight
                                        context.fill(
                                            Path(CGRect(x: cursorX, y: cursorY, width: cellWidth, height: lineHeight)),
                                            with: .color(CmuxTheme.accentGreen.opacity(0.85))
                                        )
                                    }
                                }
                                .frame(width: contentWidth, height: contentHeight)
                                .contentShape(Rectangle())
                                .simultaneousGesture(selectionGesture(
                                    snapshot: selectionSnapshot,
                                    geometry: geometry
                                ))
                                .onTapGesture {
                                    if selectionController.phase == .selected {
                                        selectionController.cancelSelection()
                                    }
                                }
                                .cmuxScanlines()

                                Color.clear
                                    .frame(width: contentWidth, height: bottomScrollPadding)
                                    .id(TerminalScrollTarget.bottom)
                            }
                            .frame(width: contentWidth, height: viewportHeight)
                            .scrollClipDisabled(false)
                            .scrollDisabled(!selectionController.allowsScrolling)
                            .accessibilityIdentifier("TerminalViewport")
                            .accessibilityLabel(String(localized: "Terminal output"))
                            .accessibilityValue(terminalAccessibilityValue)
                            .accessibilityAction(named: Text("Select all terminal text")) {
                                selectionController.performAccessibilityAction(
                                    .selectAll,
                                    snapshot: selectionSnapshot
                                )
                            }
                            .accessibilityAction(named: Text("Copy terminal selection")) {
                                selectionController.performAccessibilityAction(
                                    .copy,
                                    snapshot: selectionSnapshot
                                )
                            }
                            .accessibilityAction(.escape) {
                                selectionController.cancelSelection()
                            }
                            .onChange(of: scrollToBottomRequest) { _, _ in
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                    verticalScroll.scrollTo(TerminalScrollTarget.bottom, anchor: .bottom)
                                }
                            }
                        }
                    }
                    .frame(width: proxy.size.width, height: viewportHeight)
                    .scrollClipDisabled(false)
                    .scrollDisabled(!selectionController.allowsScrolling)

                    Color.clear.frame(height: bottomInset)
                }

                if selectionController.showsActionControls {
                    TerminalSelectionActionControls(
                        copy: { selectionController.copySelection() },
                        cancel: { selectionController.cancelSelection() }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, bottomInset + bottomSafeAreaInset + 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }

            }
            .onChange(of: store.grid.selectionEpochID) { _, _ in
                selectionController.advanceGridEpoch(reason: store.grid.selectionEpochChangeReason)
            }
            .onChange(of: store.subscribed) { oldSurface, newSurface in
                guard oldSurface != newSurface else { return }
                selectionController.advanceGridEpoch(reason: .surfaceChanged)
            }
            .onChange(of: store.rev) { _, revision in
                selectionController.ordinaryRevisionChanged(to: revision)
            }
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.005)
                    .onChanged { value in
                        if pinchAnchorFontSize == nil {
                            selectionController.pinchBegan()
                            pinchAnchorFontSize = fontMetrics.fontSize
                        }
                        let base = pinchAnchorFontSize ?? fontMetrics.fontSize
                        let size = Self.fontSizeRange.clamping(base * value.magnification)
                        if size != fontMetrics.fontSize {
                            fontMetrics = TerminalFontMetrics(fontSize: size)
                        }
                    }
                    .onEnded { value in
                        let base = pinchAnchorFontSize ?? fontMetrics.fontSize
                        let size = Self.fontSizeRange.clamping(base * value.magnification)
                        if size != fontMetrics.fontSize {
                            fontMetrics = TerminalFontMetrics(fontSize: size)
                        }
                        pinchAnchorFontSize = nil
                    }
            )
        }
        .background(CmuxTheme.terminal)
    }

    static func bottomScrollPadding(lineHeight: CGFloat) -> CGFloat {
        lineHeight * bottomScrollPaddingRows
    }

    private func selectionGesture(
        snapshot: TerminalSelectionSnapshot,
        geometry: TerminalGridGeometry
    ) -> some Gesture {
        LongPressGesture(
            minimumDuration: TerminalSelectionGesturePolicy.minimumPressDuration,
            maximumDistance: TerminalSelectionGesturePolicy.maximumPressDistance
        )
        .sequenced(before: DragGesture(
            minimumDistance: TerminalSelectionGesturePolicy.minimumDragDistance
        ))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if selectionController.phase == .idle {
                    selectionController.recognizePress(
                        at: drag.startLocation,
                        snapshot: snapshot,
                        geometry: geometry
                    )
                }
                selectionController.moveSelection(to: drag.location, geometry: geometry)
            }
            .onEnded { value in
                if case .second(true, let drag?) = value {
                    if selectionController.phase == .idle {
                        selectionController.recognizePress(
                            at: drag.startLocation,
                            snapshot: snapshot,
                            geometry: geometry
                        )
                    }
                    selectionController.moveSelection(to: drag.location, geometry: geometry)
                }
                if selectionController.phase == .selecting {
                    selectionController.endSelection()
                }
            }
    }

    private var terminalAccessibilityValue: String {
        guard selectionController.selection != nil else { return accessibilitySnapshot }
        return String(
            localized: "\(selectionController.selectedCharacterCount) characters selected across \(selectionController.selectedLineCount) lines"
        )
    }

    private var accessibilitySnapshot: String {
        store.grid.renderRows
            .prefix(6)
            .map { $0.plainText.trimmingCharacters(in: .whitespaces) }
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
        case .indexed(let value): return Self.indexedColor(value)
        case .rgb(let red, let green, let blue):
            return Color(
                red: Double(red) / 255.0,
                green: Double(green) / 255.0,
                blue: Double(blue) / 255.0
            )
        case .bright(let inner): return inner.swiftUI
        }
    }

    static func indexedColor(_ value: Int) -> Color {
        let clamped = max(0, min(255, value))
        let system: [Color] = [
            CmuxTheme.mutedDim,
            CmuxTheme.accentRed,
            CmuxTheme.accentGreen,
            CmuxTheme.accentYellow,
            CmuxTheme.accentBlue,
            CmuxTheme.accentMagenta,
            CmuxTheme.accentCyan,
            CmuxTheme.terminalText,
            CmuxTheme.muted,
            CmuxTheme.accentRed.opacity(1.0),
            CmuxTheme.accentGreen.opacity(1.0),
            CmuxTheme.accentYellow.opacity(1.0),
            CmuxTheme.accentBlue.opacity(1.0),
            CmuxTheme.accentMagenta.opacity(1.0),
            CmuxTheme.accentCyan.opacity(1.0),
            Color.white,
        ]
        if clamped < system.count { return system[clamped] }
        if clamped >= 232 {
            let shade = Double(8 + (clamped - 232) * 10) / 255.0
            return Color(red: shade, green: shade, blue: shade)
        }
        let cubeIndex = clamped - 16
        let levels = [0, 95, 135, 175, 215, 255]
        let red = levels[(cubeIndex / 36) % 6]
        let green = levels[(cubeIndex / 6) % 6]
        let blue = levels[cubeIndex % 6]
        return Color(
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0
        )
    }
}
