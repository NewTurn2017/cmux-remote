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

    /// Encodes authoritative geometry in a private CSI record ignored by legacy viewers.
    var ansiGeometrySequence: String? {
        guard let cellWidth else { return nil }
        let scalarCount = text.unicodeScalars.count
        guard scalarCount > 0 else { return nil }
        return "\u{1B}[?2026;\(column);\(cellWidth);\(scalarCount)z"
    }

    private enum CodingKeys: String, CodingKey {
        case row
        case column
        case styleID = "styleId"
        case text
        case cellWidth
    }
}
