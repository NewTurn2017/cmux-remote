import Foundation

/// Decodes and validates one authoritative `cmux.render-grid.v1` frame.
struct CMUXRenderGrid: Decodable, Equatable, Sendable {
    static let currentFormat = "cmux.render-grid.v1"

    let format: String
    let surfaceID: String
    let stateSeq: UInt64
    let renderEpoch: CMUXRenderEpoch
    let renderRevision: CMUXRenderRevision
    let columns: Int
    let rows: Int
    let cursor: CMUXRenderGridCursor?
    let full: Bool
    let clearedRows: [Int]
    let styles: [CMUXRenderGridStyle]
    let rowSpans: [CMUXRenderGridSpan]
    let activeScreen: CMUXRenderGridScreen
    let modes: [CMUXRenderGridMode]
    let terminalForeground: String?
    let terminalBackground: String?
    let terminalCursorColor: String?
    let terminalTheme: CMUXTerminalTheme?
    let terminalConfigTheme: CMUXTerminalTheme?
    let terminalThemeRevision: UInt64?
    let scrollbackRows: Int
    let scrollbackSpans: [CMUXRenderGridSpan]
    let anchor: CMUXRenderGridAnchor
    let scrolledRows: Int
    let historyRows: UInt64?
    let deltaBaseHistoryRows: UInt64?
    let rowSpaceRevision: UInt64?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decode(String.self, forKey: .format)
        let columns = try container.decode(Int.self, forKey: .columns)
        let rows = try container.decode(Int.self, forKey: .rows)
        guard format == Self.currentFormat else {
            throw CMUXRenderGridError.invalidFormat(format)
        }
        guard columns > 0, rows > 0 else {
            throw CMUXRenderGridError.invalidDimensions(columns: columns, rows: rows)
        }

        let cursor = try container.decodeIfPresent(CMUXRenderGridCursor.self, forKey: .cursor)
        if let cursor {
            guard (0..<rows).contains(cursor.row), (0..<columns).contains(cursor.column) else {
                throw CMUXRenderGridError.invalidCursor(row: cursor.row, column: cursor.column)
            }
        }

        let full = try container.decodeIfPresent(Bool.self, forKey: .full) ?? true
        let clearedRows = try container.decodeIfPresent([Int].self, forKey: .clearedRows) ?? []
        for row in clearedRows where !(0..<rows).contains(row) {
            throw CMUXRenderGridError.invalidRow(row)
        }

        let decodedStyles = try container.decodeIfPresent([CMUXRenderGridStyle].self, forKey: .styles) ?? []
        let styles = decodedStyles.isEmpty ? [.default] : decodedStyles
        let styleIDs = Set(styles.map(\.id))
        let rowSpans = try container.decode([CMUXRenderGridSpan].self, forKey: .rowSpans)
        let scrollbackRows = max(0, try container.decodeIfPresent(Int.self, forKey: .scrollbackRows) ?? 0)
        let scrollbackSpans = try container.decodeIfPresent([CMUXRenderGridSpan].self, forKey: .scrollbackSpans) ?? []
        try Self.validate(
            spans: rowSpans,
            rowCount: rows,
            columns: columns,
            styleIDs: styleIDs
        )
        try Self.validate(
            spans: scrollbackSpans,
            rowCount: scrollbackRows,
            columns: columns,
            styleIDs: styleIDs
        )

        self.format = format
        surfaceID = try container.decode(String.self, forKey: .surfaceID)
        stateSeq = try container.decode(UInt64.self, forKey: .stateSeq)
        renderEpoch = try container.decodeIfPresent(CMUXRenderEpoch.self, forKey: .renderEpoch)
            ?? CMUXRenderEpoch(rawValue: "")
        renderRevision = try container.decodeIfPresent(CMUXRenderRevision.self, forKey: .renderRevision)
            ?? CMUXRenderRevision(rawValue: 0)
        self.columns = columns
        self.rows = rows
        self.cursor = cursor
        self.full = full
        self.clearedRows = full ? [] : Array(Set(clearedRows).sorted())
        self.styles = styles
        self.rowSpans = rowSpans
        activeScreen = try container.decodeIfPresent(CMUXRenderGridScreen.self, forKey: .activeScreen) ?? .primary
        modes = try container.decodeIfPresent([CMUXRenderGridMode].self, forKey: .modes) ?? []
        terminalForeground = try container.decodeIfPresent(String.self, forKey: .terminalForeground)
        terminalBackground = try container.decodeIfPresent(String.self, forKey: .terminalBackground)
        terminalCursorColor = try container.decodeIfPresent(String.self, forKey: .terminalCursorColor)
        let decodedTheme = try container.decodeIfPresent(CMUXTerminalTheme.self, forKey: .terminalTheme)
        let decodedConfigTheme = try container.decodeIfPresent(CMUXTerminalTheme.self, forKey: .terminalConfigTheme)
        terminalTheme = full ? decodedTheme : nil
        terminalConfigTheme = full ? decodedConfigTheme : nil
        terminalThemeRevision = full
            ? try container.decodeIfPresent(UInt64.self, forKey: .terminalThemeRevision)
            : nil
        let anchor = try container.decodeIfPresent(CMUXRenderGridAnchor.self, forKey: .anchor) ?? .viewport
        let decodedScrolledRows = try container.decodeIfPresent(Int.self, forKey: .scrolledRows) ?? 0
        let resolvedScrolledRows = (full || anchor != .screen) ? 0 : max(0, decodedScrolledRows)
        let carriesScrollback = full || resolvedScrolledRows > 0
        self.scrollbackRows = carriesScrollback ? scrollbackRows : 0
        self.scrollbackSpans = carriesScrollback ? scrollbackSpans : []
        self.anchor = anchor
        scrolledRows = resolvedScrolledRows
        historyRows = try container.decodeIfPresent(UInt64.self, forKey: .historyRows)
        deltaBaseHistoryRows = full
            ? nil
            : try container.decodeIfPresent(UInt64.self, forKey: .deltaBaseHistoryRows)
        rowSpaceRevision = try container.decodeIfPresent(UInt64.self, forKey: .rowSpaceRevision)
    }

    private static func validate(
        spans: [CMUXRenderGridSpan],
        rowCount: Int,
        columns: Int,
        styleIDs: Set<Int>
    ) throws {
        var endColumnByRow: [Int: Int] = [:]
        for span in spans.sorted(by: {
            $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row
        }) {
            guard (0..<rowCount).contains(span.row) else {
                throw CMUXRenderGridError.invalidRow(span.row)
            }
            guard (0..<columns).contains(span.column) else {
                throw CMUXRenderGridError.invalidColumn(span.column)
            }
            guard styleIDs.contains(span.styleID) else {
                throw CMUXRenderGridError.invalidStyleID(span.styleID)
            }
            let width = span.gridCellWidth
            guard width > 0,
                  width <= columns - span.column,
                  span.column >= endColumnByRow[span.row, default: 0] else {
                throw CMUXRenderGridError.invalidSpanWidth(
                    row: span.row,
                    column: span.column,
                    width: width,
                    columns: columns
                )
            }
            endColumnByRow[span.row] = span.column + width
        }
    }

    private enum CodingKeys: String, CodingKey {
        case format
        case surfaceID = "surfaceId"
        case stateSeq
        case renderEpoch
        case renderRevision
        case columns
        case rows
        case cursor
        case full
        case clearedRows
        case styles
        case rowSpans
        case activeScreen
        case modes
        case terminalForeground
        case terminalBackground
        case terminalCursorColor
        case terminalTheme
        case terminalConfigTheme
        case terminalThemeRevision
        case scrollbackRows
        case scrollbackSpans
        case anchor
        case scrolledRows
        case historyRows
        case deltaBaseHistoryRows
        case rowSpaceRevision
    }
}
