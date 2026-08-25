import Foundation
import SharedKit

public struct RowState {
    private var rowHashes: [String] = []
    private var cursor: CursorPos = .init(x: -1, y: -1)
    private var previousSnapshot: Screen?

    public init() {}

    public mutating func ingest(snapshot: Screen) -> [DiffOp] {
        defer { previousSnapshot = snapshot }

        guard let previousSnapshot else {
            return replaceAll(with: snapshot)
        }
        if snapshot.requiresFullReset(comparedTo: previousSnapshot) {
            return replaceAll(with: snapshot)
        }

        var ops: [DiffOp] = []
        for i in 0..<snapshot.rows.count {
            let hash = ScreenHasher.rowHash(snapshot.rows[i])
            if hash != rowHashes[i] {
                rowHashes[i] = hash
                ops.append(.row(y: i, text: snapshot.rows[i]))
            }
        }
        if snapshot.cursor != cursor {
            cursor = snapshot.cursor
            ops.append(.cursor(x: snapshot.cursor.x, y: snapshot.cursor.y))
        }
        return ops
    }

    private mutating func replaceAll(with snapshot: Screen) -> [DiffOp] {
        rowHashes = snapshot.rows.map(ScreenHasher.rowHash)
        cursor = snapshot.cursor
        var ops: [DiffOp] = [.clear]
        for (index, row) in snapshot.rows.enumerated() {
            ops.append(.row(y: index, text: row))
        }
        ops.append(.cursor(x: snapshot.cursor.x, y: snapshot.cursor.y))
        return ops
    }
}
