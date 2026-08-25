import SharedKit
@testable import RelayCore

actor SessionStaticReader: SurfaceReader {
    private var snapshots: [Screen]

    init(_ snapshots: [Screen]) {
        self.snapshots = snapshots
    }

    func read(workspaceId: String, surfaceId: String, lines: Int) -> Screen {
        if snapshots.isEmpty {
            return Screen(rev: 0, rows: [], cols: 0, cursor: .init(x: 0, y: 0))
        }
        return snapshots.removeFirst()
    }
}
