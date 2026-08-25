import SharedKit
@testable import RelayCore

/// Deterministic screen sequence with per-surface source-read observability.
actor CountingSessionReader: SurfaceReader {
    private var snapshots: [Screen]
    private var readsBySurface: [String: Int] = [:]

    init(_ snapshots: [Screen]) {
        self.snapshots = snapshots
    }

    func read(workspaceId: String, surfaceId: String, lines: Int) -> Screen {
        readsBySurface[surfaceId, default: 0] += 1
        if snapshots.count > 1 {
            return snapshots.removeFirst()
        }
        return snapshots.first ?? Screen(
            rev: 0,
            rows: [],
            cols: 0,
            cursor: .hidden
        )
    }

    func readCount(surfaceId: String) -> Int {
        readsBySurface[surfaceId, default: 0]
    }
}
