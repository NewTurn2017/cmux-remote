import CMUXClient
import Foundation

/// Reads one terminal source snapshot at a time for a relay-owned render loop.
public protocol TerminalSourceReader: Sendable {
    /// Reads the next terminal source outcome without starting its own polling task.
    ///
    /// - Parameters:
    ///   - workspaceId: Expected workspace identifier for source validation.
    ///   - surfaceId: Surface whose viewport should be read.
    ///   - lines: Legacy plain-text line count used when replay is unsupported.
    /// - Returns: A new screen or an explicit replay skip outcome.
    /// - Throws: A transport, dispatch, or typed source-validation error.
    func readTerminal(
        workspaceId: String,
        surfaceId: String,
        lines: Int
    ) async throws -> CMUXTerminalReadOutcome

    /// Releases continuity state after the last consumer leaves a surface.
    ///
    /// - Parameters:
    ///   - workspaceId: Workspace containing the released surface.
    ///   - surfaceId: Surface whose replay identity should be forgotten.
    /// - Throws: A connection error when the source is unavailable.
    func releaseTerminalSource(workspaceId: String, surfaceId: String) async throws

    /// Resets continuity state for all surfaces while preserving negotiated capabilities.
    ///
    /// - Throws: A connection error when the source is unavailable.
    func resetTerminalSources() async throws
}
