import CoreGraphics

/// Produces content-coordinate highlight frames for a terminal selection.
struct TerminalSelectionOverlayGeometry {
    static func frames(
        for selection: TerminalSelection,
        layout: TerminalGridLayout,
        origin: CGPoint = TerminalGridGeometry.canvasOrigin
    ) -> [CGRect] {
        let range = selection.range
        var frames: [CGRect] = []

        for rowIndex in range.start.row...range.end.row {
            let row = selection.snapshot.rows[rowIndex]
            let lowerBound = rowIndex == range.start.row ? range.start.column : nil
            let upperBound = rowIndex == range.end.row ? range.end.column : nil
            let selectedSpans = row.spans.filter { span in
                let reachesLowerBound = lowerBound.map { span.columns.upperBound > $0 } ?? true
                let reachesUpperBound = upperBound.map { span.columns.lowerBound <= $0 } ?? true
                return reachesLowerBound && reachesUpperBound
            }

            if selectedSpans.isEmpty {
                if rowIndex > range.start.row, rowIndex < range.end.row {
                    frames.append(layout.frame(startColumn: 0, columns: 1, row: rowIndex)
                        .offsetBy(dx: origin.x, dy: origin.y))
                }
                continue
            }

            var groupStart = selectedSpans[0].columns.lowerBound
            var groupEnd = selectedSpans[0].columns.upperBound
            for span in selectedSpans.dropFirst() {
                if span.columns.lowerBound == groupEnd {
                    groupEnd = span.columns.upperBound
                } else {
                    frames.append(layout.frame(
                        startColumn: groupStart,
                        columns: groupEnd - groupStart,
                        row: rowIndex
                    ).offsetBy(dx: origin.x, dy: origin.y))
                    groupStart = span.columns.lowerBound
                    groupEnd = span.columns.upperBound
                }
            }
            frames.append(layout.frame(
                startColumn: groupStart,
                columns: groupEnd - groupStart,
                row: rowIndex
            ).offsetBy(dx: origin.x, dy: origin.y))
        }

        return frames
    }
}
