import XCTest
import SharedKit
@testable import RelayCore

final class SessionManagerTests: XCTestCase {
    func testFanoutByDevice() async throws {
        let mgr = SessionManager(reader: SessionStaticReader([]),
                                 defaultFps: 30, idleFps: 5)
        let inboxA = FrameInbox()
        let inboxB = FrameInbox()
        let sA = await mgr.attach(deviceId: "A") { f in inboxA.append(f) }
        _ = await mgr.attach(deviceId: "B") { f in inboxB.append(f) }

        await mgr.broadcastToDevice(deviceId: "A",
                                    frame: .ping(PingFrame(ts: 1)))

        XCTAssertEqual(inboxA.snapshot().count, 1)
        XCTAssertEqual(inboxB.snapshot().count, 0)

        await mgr.detach(session: sA)
    }

    func testBroadcastEvent() async throws {
        let mgr = SessionManager(reader: SessionStaticReader([]),
                                 defaultFps: 30, idleFps: 5)
        let inboxA = FrameInbox()
        let inboxB = FrameInbox()
        _ = await mgr.attach(deviceId: "A") { f in inboxA.append(f) }
        _ = await mgr.attach(deviceId: "B") { f in inboxB.append(f) }

        await mgr.broadcastToAll(frame: .event(EventFrame(category: .system,
                                                          name: "x",
                                                          payload: .null)))

        XCTAssertEqual(inboxA.snapshot().count, 1)
        XCTAssertEqual(inboxB.snapshot().count, 1)
    }
}

/// Thread-safe frame collector. The send closure is `@Sendable`, so the
/// sink it writes into has to be Sendable too — an actor would force a
/// Task hop, hiding ordering bugs. NSLock keeps it synchronous.
final class FrameInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [PushFrame] = []
    func append(_ f: PushFrame) {
        lock.lock(); defer { lock.unlock() }
        frames.append(f)
    }
    func snapshot() -> [PushFrame] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }
}
