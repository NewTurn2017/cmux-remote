import Foundation

/// Carries one styled run positioned in terminal columns.
struct CMUXRenderGridSpan: Decodable, Equatable, Sendable {
    let row: Int
    let column: Int
    let styleID: Int
    let text: String
    let cellWidth: Int?

    var gridCellWidth: Int {
        cellWidth ?? max(1, text.cmuxTerminalCellWidth)
    }

    private enum CodingKeys: String, CodingKey {
        case row
        case column
        case styleID = "styleId"
        case text
        case cellWidth
    }
}
