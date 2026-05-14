import Foundation
import SharedKit

public struct CellGrid: Equatable {
    public var rows: [[ANSICell]]
    public var cols: Int
    public var cursor: CursorPos = CursorPos(x: 0, y: 0)

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = Array(repeating: [], count: rows)
    }

    public mutating func replaceRow(_ y: Int, raw: String) {
        guard y >= 0 else { return }
        if y >= rows.count {
            rows.append(contentsOf: Array(repeating: [], count: y - rows.count + 1))
        }
        rows[y] = ANSIParser.parse(raw, base: .default)
    }

    public mutating func clear() {
        for index in rows.indices { rows[index] = [] }
    }
}
