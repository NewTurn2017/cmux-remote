import CoreGraphics

/// Converts terminal Canvas points into immutable snapshot positions.
struct TerminalGridGeometry: Equatable, Sendable {
    static let canvasOrigin = CGPoint(x: 16, y: 8)

    let origin: CGPoint
    let cellWidth: CGFloat
    let lineHeight: CGFloat

    init(
        origin: CGPoint = TerminalGridGeometry.canvasOrigin,
        cellWidth: CGFloat,
        lineHeight: CGFloat
    ) {
        self.origin = origin
        self.cellWidth = cellWidth
        self.lineHeight = lineHeight
    }

    /// Returns a position only when the initial point hits selectable text.
    func strictPosition(
        at point: CGPoint,
        in snapshot: TerminalSelectionSnapshot
    ) -> TerminalGridPosition? {
        guard hasValidInputs(point: point, snapshot: snapshot) else { return nil }
        let localX = point.x - origin.x
        let localY = point.y - origin.y
        guard localX >= 0, localY >= 0,
              let column = strictIndex(localX, stride: cellWidth),
              let row = strictIndex(localY, stride: lineHeight),
              snapshot.rows.indices.contains(row),
              let canonicalColumn = snapshot.rows[row].canonicalColumn(containing: column)
        else { return nil }

        return TerminalGridPosition(row: row, column: canonicalColumn)
    }

    /// Returns the nearest selectable position while an active drag leaves text bounds.
    func clampedPosition(
        at point: CGPoint,
        in snapshot: TerminalSelectionSnapshot
    ) -> TerminalGridPosition? {
        guard hasValidInputs(point: point, snapshot: snapshot),
              let rawColumn = clampedIndex(point.x - origin.x, stride: cellWidth),
              let rawRow = clampedIndex(point.y - origin.y, stride: lineHeight),
              let row = nearestSelectableRow(to: rawRow, in: snapshot),
              let column = snapshot.rows[row].clampedCanonicalColumn(for: rawColumn)
        else { return nil }

        return TerminalGridPosition(row: row, column: column)
    }

    private func hasValidInputs(
        point: CGPoint,
        snapshot: TerminalSelectionSnapshot
    ) -> Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && point.x.isFinite
            && point.y.isFinite
            && cellWidth.isFinite
            && cellWidth > 0
            && lineHeight.isFinite
            && lineHeight > 0
            && snapshot.isWellFormed
    }

    private func strictIndex(_ value: CGFloat, stride: CGFloat) -> Int? {
        let quotient = floor(value / stride)
        guard quotient.isFinite,
              quotient >= CGFloat(Int.min),
              quotient < CGFloat(Int.max)
        else { return nil }
        return Int(quotient)
    }

    private func clampedIndex(_ value: CGFloat, stride: CGFloat) -> Int? {
        let quotient = floor(value / stride)
        guard quotient.isFinite else { return nil }
        if quotient <= CGFloat(Int.min) { return Int.min }
        if quotient >= CGFloat(Int.max) { return Int.max }
        return Int(quotient)
    }

    private func nearestSelectableRow(
        to target: Int,
        in snapshot: TerminalSelectionSnapshot
    ) -> Int? {
        snapshot.rows.indices
            .filter { !snapshot.rows[$0].spans.isEmpty }
            .min { lhs, rhs in
                let lhsDistance = abs(Double(lhs) - Double(target))
                let rhsDistance = abs(Double(rhs) - Double(target))
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return lhs < rhs
            }
    }
}
