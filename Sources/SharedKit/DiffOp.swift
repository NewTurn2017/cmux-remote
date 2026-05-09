import Foundation

public enum DiffOp: Codable, Sendable, Equatable {
    case row(y: Int, text: String)
    case cursor(x: Int, y: Int)
    case clear

    private enum CodingKeys: String, CodingKey { case op, y, x, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .op) {
        case "row":    self = .row(y: try c.decode(Int.self, forKey: .y),
                                   text: try c.decode(String.self, forKey: .text))
        case "cursor": self = .cursor(x: try c.decode(Int.self, forKey: .x),
                                      y: try c.decode(Int.self, forKey: .y))
        case "clear":  self = .clear
        case let other: throw DecodingError.dataCorruptedError(
            forKey: .op, in: c, debugDescription: "Unknown op: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .row(let y, let text):
            try c.encode("row",    forKey: .op)
            try c.encode(y,        forKey: .y)
            try c.encode(text,     forKey: .text)
        case .cursor(let x, let y):
            try c.encode("cursor", forKey: .op)
            try c.encode(x,        forKey: .x)
            try c.encode(y,        forKey: .y)
        case .clear:
            try c.encode("clear",  forKey: .op)
        }
    }

    /// Compute the minimal set of ops that transforms `from` into `to`.
    /// Row count mismatches emit a `.clear` followed by full row replacements.
    public static func compute(from old: Screen, to new: Screen) -> [DiffOp] {
        var ops: [DiffOp] = []
        if old.rows.count != new.rows.count {
            ops.append(.clear)
            for (i, row) in new.rows.enumerated() { ops.append(.row(y: i, text: row)) }
        } else {
            for i in 0..<new.rows.count where old.rows[i] != new.rows[i] {
                ops.append(.row(y: i, text: new.rows[i]))
            }
        }
        if old.cursor != new.cursor {
            ops.append(.cursor(x: new.cursor.x, y: new.cursor.y))
        }
        return ops
    }

    /// Apply ops in order, mutating `screen` to match the source side's `new`.
    public static func apply(_ ops: [DiffOp], to screen: inout Screen) {
        for op in ops {
            switch op {
            case .clear:
                screen.rows = Array(repeating: "", count: screen.rows.count)
            case .row(let y, let text):
                if y >= screen.rows.count {
                    screen.rows.append(contentsOf: Array(repeating: "", count: y - screen.rows.count + 1))
                }
                screen.rows[y] = text
            case .cursor(let x, let y):
                screen.cursor = CursorPos(x: x, y: y)
            }
        }
    }
}
