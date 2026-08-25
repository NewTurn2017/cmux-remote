import Foundation

/// Reports a structurally invalid `cmux.render-grid.v1` frame.
enum CMUXRenderGridError: Error, Equatable, Sendable {
    case invalidFormat(String)
    case invalidDimensions(columns: Int, rows: Int)
    case invalidRow(Int)
    case invalidColumn(Int)
    case invalidCursor(row: Int, column: Int)
    case invalidStyleID(Int)
    case invalidSpanWidth(row: Int, column: Int, width: Int, columns: Int)
}
