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

    func testActiveSessionCountObserverSeesAttachAndDetachInOrder() async throws {
        let mgr = SessionManager(reader: SessionStaticReader([]),
                                 defaultFps: 30, idleFps: 5)
        let counts = SessionCountInbox()
        await mgr.setActiveSessionCountObserver { counts.append($0) }

        let sA = await mgr.attach(deviceId: "A") { _ in }
        let sB = await mgr.attach(deviceId: "B") { _ in }
        await mgr.detach(session: sA)
        await mgr.detach(session: sB)

        XCTAssertEqual(counts.snapshot(), [1, 2, 1, 0])
        let remaining = await mgr.activeSessionCount
        XCTAssertEqual(remaining, 0)
    }
}

final class SessionCountInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []
    func append(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        counts.append(count)
    }
    func snapshot() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return counts
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
