import Foundation
import SharedKit

public protocol SurfaceReader: Sendable {
    func read(workspaceId: String, surfaceId: String, lines: Int) async throws -> Screen
}

/// Per-surface diff polling state.
///
/// Actor-isolated so that `noteUserInput()` (called from the WS handler when a
/// device sends input) and `tick()` (called from the NIO event loop's polling
/// timer) cannot race on the mutable state — `lastInput`, `currentFps`,
/// `state`, `rev`, `lastChecksumAt`, and the two callback slots.
public actor DiffEngine {
    public nonisolated let workspaceId: String
    public nonisolated let surfaceId: String
    public nonisolated let lines: Int
    public nonisolated let activeFps: Int
    public nonisolated let idleFps: Int
    public nonisolated let idleAfter: TimeInterval = 1.5

    public private(set) var rev: Int = 0
    public private(set) var currentFps: Int

    private let reader: SurfaceReader
    private let clock: Clock
    private var state = RowState()
    private var lastInput: TimeInterval
    private var lastChecksumAt: TimeInterval = 0
    private var onDiff: (@Sendable ([DiffOp]) -> Void)?
    private var onChecksum: (@Sendable (String, Int) -> Void)?

    public init(reader: SurfaceReader,
                fps: Int, idleFps: Int,
                workspaceId: String, surfaceId: String, lines: Int,
                clock: Clock = SystemClock())
    {
        self.reader = reader
        self.activeFps = fps
        self.idleFps = idleFps
        self.currentFps = fps
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.lines = lines
        self.clock = clock
        self.lastInput = clock.now
    }

    public func setOnDiff(_ handler: (@Sendable ([DiffOp]) -> Void)?) {
        self.onDiff = handler
    }

    public func setOnChecksum(_ handler: (@Sendable (String, Int) -> Void)?) {
        self.onChecksum = handler
    }

    public func noteUserInput() {
        lastInput = clock.now
        currentFps = activeFps
    }

    /// Run one polling tick. In production wired to a NIO TimerTask at 1/currentFps.
    public func tick() async throws {
        if clock.now - lastInput > idleAfter { currentFps = idleFps }
        let snapshot = try await reader.read(workspaceId: workspaceId,
                                             surfaceId: surfaceId, lines: lines)
        let ops = state.ingest(snapshot: snapshot)
        if !ops.isEmpty {
            rev &+= 1
            onDiff?(ops)
        }
        if clock.now - lastChecksumAt >= 5.0 {
            lastChecksumAt = clock.now
            onChecksum?(ScreenHasher.hash(snapshot), rev)
        }
    }
}
