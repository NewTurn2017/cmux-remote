import CoreGraphics

struct TerminalGridLayout {
    let cellWidth: CGFloat
    let lineHeight: CGFloat

    func frame(startColumn: Int, columns: Int, row: Int) -> CGRect {
        CGRect(
            x: CGFloat(startColumn) * cellWidth,
            y: CGFloat(row) * lineHeight,
            width: CGFloat(columns) * cellWidth,
            height: lineHeight
        )
    }
}
