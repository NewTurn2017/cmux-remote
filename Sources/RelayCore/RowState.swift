import Foundation
import SharedKit

public struct RowState {
    private var rowHashes: [String] = []
    private var cursor: CursorPos = .init(x: -1, y: -1)
    private var initialised = false

    public init() {}

    public mutating func ingest(snapshot: Screen) -> [DiffOp] {
        if !initialised {
            initialised = true
            rowHashes = snapshot.rows.map(ScreenHasher.rowHash)
            cursor = snapshot.cursor
            var ops: [DiffOp] = [.clear]
            for (i, row) in snapshot.rows.enumerated() { ops.append(.row(y: i, text: row)) }
            ops.append(.cursor(x: snapshot.cursor.x, y: snapshot.cursor.y))
            return ops
        }
        var ops: [DiffOp] = []
        if snapshot.rows.count != rowHashes.count {
            ops.append(.clear)
            rowHashes = snapshot.rows.map(ScreenHasher.rowHash)
            for (i, row) in snapshot.rows.enumerated() { ops.append(.row(y: i, text: row)) }
        } else {
            for i in 0..<snapshot.rows.count {
                let h = ScreenHasher.rowHash(snapshot.rows[i])
                if h != rowHashes[i] {
                    rowHashes[i] = h
                    ops.append(.row(y: i, text: snapshot.rows[i]))
                }
            }
        }
        if snapshot.cursor != cursor {
            cursor = snapshot.cursor
            ops.append(.cursor(x: snapshot.cursor.x, y: snapshot.cursor.y))
        }
        return ops
    }
}
