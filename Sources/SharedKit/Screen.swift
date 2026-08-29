import Foundation

public struct CursorPos: Codable, Sendable, Equatable {
    /// A wire-compatible sentinel that prevents terminal renderers from painting a cursor.
    public static let hidden = CursorPos(x: -1, y: -1)

    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }

    /// Returns whether the cursor occupies a cell inside the rendered grid bounds.
    ///
    /// - Parameters:
    ///   - columns: Number of renderable terminal columns.
    ///   - rows: Number of renderable terminal rows.
    /// - Returns: `true` only when both coordinates are nonnegative and in range.
    public func isRenderable(columns: Int, rows: Int) -> Bool {
        x >= 0 && y >= 0 && x < columns && y < rows
    }
}

public struct Screen: Codable, Sendable, Equatable {
    public var rev: Int
    public var rows: [String]   // raw ANSI lines, viewer-side parsing
    public var cols: Int
    public var cursor: CursorPos

    /// Relay-internal render source identity, omitted from the established Codable shape.
    public var snapshotMetadata: ScreenSnapshotMetadata?

    /// Creates an authoritative terminal screen snapshot.
    ///
    /// - Parameters:
    ///   - rev: Relay-owned delivery revision.
    ///   - rows: Raw ANSI rows used for rendering, hashing, and diffs.
    ///   - cols: Render-grid terminal column count.
    ///   - cursor: Cursor position in retained-screen coordinates.
    ///   - snapshotMetadata: Optional render source identity used only for reset decisions.
    public init(
        rev: Int,
        rows: [String],
        cols: Int,
        cursor: CursorPos,
        snapshotMetadata: ScreenSnapshotMetadata? = nil
    ) {
        self.rev = rev
        self.rows = rows
        self.cols = cols
        self.cursor = cursor
        self.snapshotMetadata = snapshotMetadata
    }

    /// Returns whether this snapshot needs clear-and-replace semantics relative to another.
    ///
    /// Source revision alone does not reset the screen: ordinary revisions remain eligible
    /// for row and cursor diffs. Geometry, epoch, and resolved theme-default changes reset.
    ///
    /// - Parameter previous: The previously ingested authoritative snapshot.
    /// - Returns: `true` when incremental row operations cannot safely preserve state.
    public func requiresFullReset(comparedTo previous: Screen) -> Bool {
        guard cols == previous.cols, rows.count == previous.rows.count else { return true }

        switch (previous.snapshotMetadata, snapshotMetadata) {
        case (nil, nil):
            return false
        case (.some, nil), (nil, .some):
            return true
        case (.some(let old), .some(let new)):
            return old.renderEpoch != new.renderEpoch
                || old.viewportRows != new.viewportRows
                || old.terminalForeground != new.terminalForeground
                || old.terminalBackground != new.terminalBackground
                || old.terminalThemeRevision != new.terminalThemeRevision
        }
    }

    /// Decodes the established four-field screen representation.
    ///
    /// Relay-internal ``snapshotMetadata`` is intentionally not transported.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rev = try container.decode(Int.self, forKey: .rev)
        rows = try container.decode([String].self, forKey: .rows)
        cols = try container.decode(Int.self, forKey: .cols)
        cursor = try container.decode(CursorPos.self, forKey: .cursor)
        snapshotMetadata = nil
    }

    /// Encodes the established four-field screen representation.
    ///
    /// Relay-internal ``snapshotMetadata`` is intentionally not transported.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rev, forKey: .rev)
        try container.encode(rows, forKey: .rows)
        try container.encode(cols, forKey: .cols)
        try container.encode(cursor, forKey: .cursor)
    }

    private enum CodingKeys: String, CodingKey {
        case rev
        case rows
        case cols
        case cursor
    }
}
