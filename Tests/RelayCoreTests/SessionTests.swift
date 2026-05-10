import XCTest
import SharedKit
@testable import RelayCore

final class SessionTests: XCTestCase {
    func testSubscribeStartsDiffEngineAndUnsubscribeStops() async throws {
        let reader = SessionStaticReader([
            Screen(rev: 1, rows: ["x"], cols: 1, cursor: .init(x: 0, y: 0))
        ])
        let session = Session(deviceId: "d1", reader: reader, defaultFps: 30, idleFps: 5)
        await session.subscribe(workspaceId: "w", surfaceId: "s", lines: 1)
        let activeBefore = await session.activeSurfaceCount
        XCTAssertEqual(activeBefore, 1)
        await session.unsubscribe(surfaceId: "s")
        let activeAfter = await session.activeSurfaceCount
        XCTAssertEqual(activeAfter, 0)
    }
}

actor SessionStaticReader: SurfaceReader {
    private var snapshots: [Screen]
    init(_ snapshots: [Screen]) { self.snapshots = snapshots }
    func read(workspaceId: String, surfaceId: String, lines: Int) async throws -> Screen {
        if snapshots.isEmpty {
            return Screen(rev: 0, rows: [], cols: 0, cursor: .init(x: 0, y: 0))
        }
        return snapshots.removeFirst()
    }
}
