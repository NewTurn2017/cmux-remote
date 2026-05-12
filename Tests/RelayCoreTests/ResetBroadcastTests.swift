import XCTest
import SharedKit
@testable import RelayCore

final class ResetBroadcastTests: XCTestCase {
    func testBroadcastResetEmitsSystemEventToAllSessions() async throws {
        let mgr = SessionManager(reader: SessionStaticReader([]),
                                 defaultFps: 15,
                                 idleFps: 5)
        let inboxA = FrameInbox()
        let inboxB = FrameInbox()
        _ = await mgr.attach(deviceId: "A") { inboxA.append($0) }
        _ = await mgr.attach(deviceId: "B") { inboxB.append($0) }

        await mgr.broadcastReset()

        try assertResetEvent(inboxA.snapshot().only)
        try assertResetEvent(inboxB.snapshot().only)
    }

    private func assertResetEvent(_ frame: PushFrame?, file: StaticString = #filePath, line: UInt = #line) throws {
        guard case .event(let event)? = frame else {
            return XCTFail("expected system reset event", file: file, line: line)
        }
        XCTAssertEqual(event.category, .system, file: file, line: line)
        XCTAssertEqual(event.name, "cmux.reset", file: file, line: line)
        XCTAssertEqual(event.payload, .null, file: file, line: line)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
