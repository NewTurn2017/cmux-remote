import Foundation
import SharedKit

public protocol SurfaceReader: Sendable {
    func read(workspaceId: String, surfaceId: String, lines: Int) async throws -> Screen
}

public final class DiffEngine: @unchecked Sendable {
    public let workspaceId: String
    public let surfaceId: String
    public let lines: Int
    public let activeFps: Int
    public let idleFps: Int
    public let idleAfter: TimeInterval = 1.5

    public var onDiff: (([DiffOp]) -> Void)?
    public var onChecksum: ((String, Int) -> Void)?
    public private(set) var rev: Int = 0
    public private(set) var currentFps: Int

    private let reader: SurfaceReader
    private let clock: Clock
    private var state = RowState()
    private var lastInput: TimeInterval
    private var lastChecksumAt: TimeInterval = 0

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
