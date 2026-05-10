import Foundation
import SharedKit

/// Per-WS connection state. Holds the device id, one DiffEngine per
/// subscribed surface, the polling Tasks driving them, and the outbound
/// frame channel. Actor-isolated because subscribe / unsubscribe / close
/// can race with the WS read path and the polling tasks themselves.
public actor Session {
    public let deviceId: String
    public var sendFrame: (@Sendable (PushFrame) -> Void)?

    private let reader: SurfaceReader
    private let defaultFps: Int
    private let idleFps: Int
    private var engines: [String: DiffEngine] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    public var activeSurfaceCount: Int { engines.count }

    public init(deviceId: String,
                reader: SurfaceReader,
                defaultFps: Int,
                idleFps: Int)
    {
        self.deviceId = deviceId
        self.reader = reader
        self.defaultFps = defaultFps
        self.idleFps = idleFps
    }

    public func update(sendFrame: (@Sendable (PushFrame) -> Void)?) {
        self.sendFrame = sendFrame
    }

    /// Push a frame to the connected client through the installed
    /// sendFrame closure. Called by SessionManager on a broadcast.
    public func send(frame: PushFrame) {
        sendFrame?(frame)
    }

    public func subscribe(workspaceId: String, surfaceId: String, lines: Int) async {
        guard engines[surfaceId] == nil else { return }
        let engine = DiffEngine(reader: reader,
                                fps: defaultFps, idleFps: idleFps,
                                workspaceId: workspaceId, surfaceId: surfaceId, lines: lines)
        engines[surfaceId] = engine
        let send = self.sendFrame
        await engine.setOnDiff { rev, ops in
            send?(.screenDiff(ScreenDiff(surfaceId: surfaceId, rev: rev, ops: ops)))
        }
        await engine.setOnChecksum { hash, rev in
            send?(.screenChecksum(ScreenChecksum(surfaceId: surfaceId, rev: rev, hash: hash)))
        }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let fps = max(1, await self.fps(for: surfaceId))
                let interval = 1.0 / Double(fps)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                try? await engine.tick()
            }
        }
        tasks[surfaceId] = task
    }

    public func unsubscribe(surfaceId: String) {
        tasks[surfaceId]?.cancel()
        tasks[surfaceId] = nil
        engines[surfaceId] = nil
    }

    public func noteUserInput(surfaceId: String) async {
        await engines[surfaceId]?.noteUserInput()
    }

    public func close() {
        for (_, t) in tasks { t.cancel() }
        tasks.removeAll()
        engines.removeAll()
    }

    private func fps(for surfaceId: String) async -> Int {
        guard let engine = engines[surfaceId] else { return defaultFps }
        return await engine.currentFps
    }
}
