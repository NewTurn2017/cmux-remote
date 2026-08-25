import CMUXClient
import Foundation

/// Adapts an existing plain-text reader to the capability-aware source seam.
struct LegacyTerminalSourceReader: TerminalSourceReader {
    let reader: any SurfaceReader

    func readTerminal(
        workspaceId: String,
        surfaceId: String,
        lines: Int
    ) async throws -> CMUXTerminalReadOutcome {
        let screen = try await reader.read(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lines: lines
        )
        return .updated(CMUXTerminalReadUpdate(
            screen: screen,
            sourceMode: .legacyText,
            replayIdentity: nil
        ))
    }

    func releaseTerminalSource(workspaceId: String, surfaceId: String) async throws {}

    func resetTerminalSources() async throws {}
}
