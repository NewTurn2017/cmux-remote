import Foundation

public struct CursorPos: Codable, Sendable, Equatable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public struct Screen: Codable, Sendable, Equatable {
    public var rev: Int
    public var rows: [String]   // raw ANSI lines, viewer-side parsing
    public var cols: Int
    public var cursor: CursorPos
    public init(rev: Int, rows: [String], cols: Int, cursor: CursorPos) {
        self.rev = rev; self.rows = rows; self.cols = cols; self.cursor = cursor
    }
}
