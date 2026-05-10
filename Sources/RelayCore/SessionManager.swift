import Foundation
import SharedKit

/// Owns the lifetime of all connected `Session`s, indexes them by device
/// id for per-device fanout, and exposes broadcast helpers used by both
/// the WS handler (per-device push) and the cmux event stream (global
/// fanout). Actor-isolated because attach / detach / broadcast can race
/// with the WS read paths and the cmux event subscriber.
public actor SessionManager {
    private let reader: SurfaceReader
    private let defaultFps: Int
    private let idleFps: Int
    private var sessionsById: [ObjectIdentifier: Session] = [:]
    private var byDevice: [String: Set<ObjectIdentifier>] = [:]

    public init(reader: SurfaceReader, defaultFps: Int, idleFps: Int) {
        self.reader = reader
        self.defaultFps = defaultFps
        self.idleFps = idleFps
    }

    public var activeSessionCount: Int { sessionsById.count }

    /// Build a Session, install its `sendFrame` closure, and index it by
    /// (object identity) and device id. Returns the new Session so the
    /// caller can drive subscribe / unsubscribe directly.
    public func attach(deviceId: String,
                       send: @escaping @Sendable (PushFrame) -> Void) async -> Session
    {
        let s = Session(deviceId: deviceId, reader: reader,
                        defaultFps: defaultFps, idleFps: idleFps)
        await s.update(sendFrame: send)
        let key = ObjectIdentifier(s)
        sessionsById[key] = s
        byDevice[deviceId, default: []].insert(key)
        return s
    }

    /// Drop the session from both indices and close it (cancels all
    /// polling tasks, drops engines).
    public func detach(session: Session) async {
        let key = ObjectIdentifier(session)
        sessionsById[key] = nil
        for (dev, set) in byDevice {
            var next = set
            next.remove(key)
            byDevice[dev] = next.isEmpty ? nil : next
        }
        await session.close()
    }

    /// Push a frame to every session bound to `deviceId` (typically one,
    /// but the WS protocol allows multiple concurrent connections per
    /// device — e.g. iPhone + iPad).
    public func broadcastToDevice(deviceId: String, frame: PushFrame) async {
        let keys = byDevice[deviceId] ?? []
        let sessions = keys.compactMap { sessionsById[$0] }
        for s in sessions {
            await s.send(frame: frame)
        }
    }

    /// Push a frame to every connected session — used for cmux event
    /// stream fanout (workspace.created etc.) and for boot_id reset
    /// notifications.
    public func broadcastToAll(frame: PushFrame) async {
        for s in sessionsById.values {
            await s.send(frame: frame)
        }
    }
}
