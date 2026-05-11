import Foundation
import RelayCore
import CMUXClient
import SharedKit

/// `SurfaceReader` implementation that pulls screens from the live cmux
/// UDS. `DiffEngine` calls this on every tick of its polling loop, so the
/// underlying `CmuxConnection.connect()` is expected to return the
/// already-warm client after the first call.
public final class CmuxSurfaceReader: SurfaceReader, @unchecked Sendable {
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
}
