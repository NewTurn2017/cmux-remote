import Foundation

/// Identifies the daemon API used to obtain a terminal snapshot.
public enum CMUXTerminalSourceMode: Equatable, Sendable {
    /// A verified `cmux.render-grid.v1` snapshot from `terminal.replay`.
    case renderGrid

    /// A plain-text snapshot from `surface.read_text`.
    case legacyText
}
