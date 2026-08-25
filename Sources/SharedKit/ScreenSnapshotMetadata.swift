import Foundation

/// Carries relay-internal render source identity separately from terminal row payloads.
///
/// ANSI rows remain authoritative for rendering, hashing, and row diffs. This metadata
/// exists only to decide when geometry or source identity requires a full reset.
public struct ScreenSnapshotMetadata: Sendable, Equatable {
    /// The producer lifetime that generated the snapshot.
    public var renderEpoch: String

    /// The monotonic render revision within ``renderEpoch``.
    public var renderRevision: UInt64

    /// The render grid's viewport row count before scrollback retention.
    public var viewportRows: Int

    /// The resolved default foreground encoded into default-styled ANSI cells.
    public var terminalForeground: String

    /// The resolved default background encoded into default-styled ANSI cells.
    public var terminalBackground: String

    /// The source theme revision, when the producer supplies one.
    public var terminalThemeRevision: UInt64?

    /// Creates render source metadata for an authoritative screen snapshot.
    ///
    /// - Parameters:
    ///   - renderEpoch: Producer lifetime identifier.
    ///   - renderRevision: Monotonic revision within the producer lifetime.
    ///   - viewportRows: Render-grid viewport height before retained scrollback is prepended.
    ///   - terminalForeground: Resolved default foreground encoded into ANSI rows.
    ///   - terminalBackground: Resolved default background encoded into ANSI rows.
    ///   - terminalThemeRevision: Optional producer theme revision.
    public init(
        renderEpoch: String,
        renderRevision: UInt64,
        viewportRows: Int,
        terminalForeground: String,
        terminalBackground: String,
        terminalThemeRevision: UInt64?
    ) {
        self.renderEpoch = renderEpoch
        self.renderRevision = renderRevision
        self.viewportRows = viewportRows
        self.terminalForeground = terminalForeground
        self.terminalBackground = terminalBackground
        self.terminalThemeRevision = terminalThemeRevision
    }
}
