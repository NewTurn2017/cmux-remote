import Foundation
import RelayCore
import CMUXClient
import SharedKit

/// `SurfaceReader` implementation that pulls screens from the live cmux
/// UDS. `DiffEngine` calls this on every tick of its polling loop, so the
/// underlying `CmuxConnection.connect()` is expected to return the
/// already-warm client after the first call.
public final class CmuxSurfaceReader: SurfaceReader, TerminalSourceReader, Sendable {
    private let connection: CmuxConnection

    public init(connection: CmuxConnection) {
        self.connection = connection
    }

    public func read(workspaceId: String, surfaceId: String, lines: Int) async throws -> Screen {
        let client = try await connection.connect()
        return try await client.surfaceReadText(workspaceId: workspaceId,
                                                surfaceId: surfaceId,
                                                lines: lines)
    }

    /// Reads one capability-selected terminal source outcome for the shared render hub.
    ///
    /// - Parameters:
    ///   - workspaceId: Expected workspace identifier for source validation.
    ///   - surfaceId: Surface whose viewport should be read.
    ///   - lines: Legacy plain-text line count used when replay is unsupported.
    /// - Returns: A new screen or an explicit replay skip outcome.
    /// - Throws: A connection, dispatch, or typed source-validation error.
    public func readTerminal(
        workspaceId: String,
        surfaceId: String,
        lines: Int
    ) async throws -> CMUXTerminalReadOutcome {
        let client = try await connection.connect()
        return try await client.terminalRead(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lines: lines
        )
    }

    /// Releases continuity state after the last consumer leaves a surface.
    ///
    /// - Parameters:
    ///   - workspaceId: Workspace containing the released surface.
    ///   - surfaceId: Surface whose replay identity should be forgotten.
    /// - Throws: A connection error when cmux is unavailable.
    public func releaseTerminalSource(workspaceId: String, surfaceId: String) async throws {
        let client = try await connection.connect()
        await client.releaseTerminalSource(workspaceId: workspaceId, surfaceId: surfaceId)
    }

    /// Resets continuity state for all surfaces on the current client, when connected.
    ///
    /// - Throws: A connection error when cmux is unavailable.
    public func resetTerminalSources() async throws {
        let client = try await connection.connect()
        await client.resetTerminalSources()
    }
}
