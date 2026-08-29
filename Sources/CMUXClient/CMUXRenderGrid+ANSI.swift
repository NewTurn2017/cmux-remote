import Foundation

extension CMUXRenderGrid {
    /// Produces deterministic ANSI rows with scrollback before the viewport.
    func canonicalANSIRows() -> [String] {
        ansiRows(from: scrollbackSpans, count: scrollbackRows)
            + ansiRows(from: rowSpans, count: rows)
    }

    private func ansiRows(from spans: [CMUXRenderGridSpan], count: Int) -> [String] {
        let foreground = resolvedTerminalForeground
        let background = resolvedTerminalBackground
        let defaultStyle = styles.first { $0.id == 0 } ?? .default
        let stylesByID = Dictionary(styles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let spansByRow = Dictionary(grouping: spans, by: \.row)

        return (0..<count).map { row in
            var ansi = ""
            var occupiedColumns = 0
            var activeBold = false
            var activeUnderline = false
            let orderedSpans = (spansByRow[row] ?? []).enumerated().sorted {
                if $0.element.column == $1.element.column {
                    return $0.offset < $1.offset
                }
                return $0.element.column < $1.element.column
            }.map(\.element)

            for span in orderedSpans {
                if occupiedColumns < span.column {
                    ansi += defaultStyle.ansiSequence(
                        defaultForeground: foreground,
                        defaultBackground: background,
                        previousBold: activeBold,
                        previousUnderline: activeUnderline
                    )
                    ansi += String(repeating: " ", count: span.column - occupiedColumns)
                    activeBold = defaultStyle.bold
                    activeUnderline = defaultStyle.underline
                }
                let style = stylesByID[span.styleID] ?? defaultStyle
                ansi += style.ansiSequence(
                    defaultForeground: foreground,
                    defaultBackground: background,
                    previousBold: activeBold,
                    previousUnderline: activeUnderline
                )
                if let geometrySequence = span.ansiGeometrySequence {
                    ansi += geometrySequence
                }
                ansi += span.text
                occupiedColumns = span.column + span.gridCellWidth
                activeBold = style.bold
                activeUnderline = style.underline
            }
            ansi += "\u{1B}[0m"
            return ansi
        }
    }

    var resolvedTerminalForeground: String {
        if let terminalForeground = terminalForeground?.cmuxNormalizedRGB {
            return terminalForeground
        }
        if let themeForeground = terminalTheme?.foreground?.cmuxNormalizedRGB {
            return themeForeground
        }
        if let configForeground = terminalConfigTheme?.foreground?.cmuxNormalizedRGB {
            return configForeground
        }
        return "#ffffff"
    }

    var resolvedTerminalBackground: String {
        if let terminalBackground = terminalBackground?.cmuxNormalizedRGB {
            return terminalBackground
        }
        if let themeBackground = terminalTheme?.background?.cmuxNormalizedRGB {
            return themeBackground
        }
        if let configBackground = terminalConfigTheme?.background?.cmuxNormalizedRGB {
            return configBackground
        }
        return "#000000"
    }
}
