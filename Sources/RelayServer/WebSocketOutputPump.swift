import Foundation
import NIOCore
import RelayCore
import SharedKit

/// Serializes bounded WebSocket writes on one NIO event loop.
///
/// The queue is capped at ``defaultMaximumQueuedBytes`` and
/// ``defaultMaximumQueuedFrames``. When more than one terminal update for a surface waits
/// behind backpressure, older updates are replaced by
/// the newest authoritative `screen.full`. Critical output is never removed or reordered;
/// overflow that cannot be resolved by terminal replacement closes the channel.
///
/// `@unchecked Sendable` is sound because every mutation is preconditioned onto `channel.eventLoop`.
final class WebSocketOutputPump: @unchecked Sendable {
    static let defaultMaximumQueuedBytes = 2 * 1024 * 1024
    static let defaultMaximumQueuedFrames = 1_024

    private(set) var metrics = WebSocketOutputPumpMetrics()
    private(set) var queuedBytes = 0
    private(set) var hasWriteInFlight = false
    private(set) var isClosed = false

    var queuedFrameCount: Int { queue.count }
    var terminalRevisionStateCount: Int { terminalRevisionStates.count }
    var pendingRetirementCount: Int { pendingRetirement == nil ? 0 : 1 }

    private let channel: any WebSocketOutputChannel
    private let maximumQueuedBytes: Int
    private let maximumQueuedFrames: Int
    private var queue: [WebSocketQueuedOutput] = []
    private var terminalRevisionStates: [String: WebSocketTerminalRevisionState] = [:]
    private var pendingRetirement: WebSocketTerminalIdentity?
    private var inFlightTerminalIdentity: WebSocketTerminalIdentity?

    init(
        channel: any WebSocketOutputChannel,
        maximumQueuedBytes: Int = WebSocketOutputPump.defaultMaximumQueuedBytes,
        maximumQueuedFrames: Int = WebSocketOutputPump.defaultMaximumQueuedFrames
    ) {
        self.channel = channel
        self.maximumQueuedBytes = max(1, maximumQueuedBytes)
        self.maximumQueuedFrames = max(1, maximumQueuedFrames)
    }

    /// Enqueues a session frame, coalescing terminal state when necessary.
    func enqueue(_ output: SessionOutboundFrame) {
        precondition(channel.eventLoop.inEventLoop)
        guard !isClosed else { return }

        do {
            let text = try Self.encode(output.frame)
            let entry: WebSocketQueuedOutput
            if let recovery = output.recoveryFull,
               let surfaceId = output.terminalSurfaceId,
               let streamIdentity = output.streamIdentity,
               let revision = output.revision
            {
                let recoveryText = try Self.encode(.screenFull(recovery))
                entry = try WebSocketQueuedOutput(
                    text: text,
                    kind: .screen(
                        surfaceId: surfaceId,
                        streamIdentity: streamIdentity,
                        revision: revision,
                        recoveryText: recoveryText,
                        frameKind: Self.frameKind(output.frame)
                    )
                )
            } else if output.recoveryFull == nil {
                entry = try WebSocketQueuedOutput(text: text, kind: .critical)
            } else {
                throw WebSocketOutputEncodingError.missingStreamIdentity
            }
            enqueue(entry)
        } catch {
            metrics.encodingFailures += 1
            closeDiscardingQueue()
        }
    }

    /// Enqueues an encoded RPC/control response that must retain FIFO order.
    func enqueueCritical(_ text: String) {
        precondition(channel.eventLoop.inEventLoop)
        guard !isClosed else { return }
        do {
            enqueue(try WebSocketQueuedOutput(text: text, kind: .critical))
        } catch {
            metrics.encodingFailures += 1
            closeDiscardingQueue()
        }
    }

    /// Retires queued and revision state for one exact surface subscription generation.
    func retire(surfaceId: String, streamIdentity: UUID) {
        precondition(channel.eventLoop.inEventLoop)
        guard !isClosed else { return }
        let identity = WebSocketTerminalIdentity(
            surfaceId: surfaceId,
            streamIdentity: streamIdentity
        )
        var retained: [WebSocketQueuedOutput] = []
        retained.reserveCapacity(queue.count)
        var removedBytes = 0
        var removedFrames = 0
        for entry in queue {
            let shouldRemove: Bool
            switch entry.kind {
            case .critical:
                shouldRemove = false
            case .screen(let queuedSurfaceId, let queuedStreamIdentity, _, _, _):
                shouldRemove = queuedSurfaceId == surfaceId
                    && queuedStreamIdentity == streamIdentity
            }
            if shouldRemove {
                let (nextRemovedBytes, overflow) = removedBytes.addingReportingOverflow(
                    entry.retainedFramedByteCount
                )
                guard !overflow else {
                    closeDiscardingQueue()
                    return
                }
                removedBytes = nextRemovedBytes
                removedFrames += 1
            } else {
                retained.append(entry)
            }
        }
        let (remainingBytes, underflow) = queuedBytes.subtractingReportingOverflow(removedBytes)
        guard !underflow, remainingBytes >= 0 else {
            closeDiscardingQueue()
            return
        }
        queue = retained
        queuedBytes = remainingBytes
        metrics.discardedFrames += removedFrames

        if inFlightTerminalIdentity == identity {
            pendingRetirement = identity
        } else {
            clearRevisionState(identity)
        }
    }

    /// Resumes pumping after NIO reports a writability transition.
    func writabilityChanged() {
        precondition(channel.eventLoop.inEventLoop)
        drain()
    }

    /// Discards pending output and closes the underlying channel once.
    func close() {
        precondition(channel.eventLoop.inEventLoop)
        guard !isClosed else { return }
        closeDiscardingQueue()
    }

    /// Marks an already-inactive channel closed and deterministically drops pending output.
    func channelClosed() {
        precondition(channel.eventLoop.inEventLoop)
        guard !isClosed else { return }
        isClosed = true
        metrics.discardedFrames += queue.count
        queue.removeAll(keepingCapacity: false)
        terminalRevisionStates.removeAll(keepingCapacity: false)
        pendingRetirement = nil
        inFlightTerminalIdentity = nil
        queuedBytes = 0
        hasWriteInFlight = false
    }

    private func enqueue(_ entry: WebSocketQueuedOutput) {
        switch entry.kind {
        case .critical:
            guard appendWithinBound(entry) else {
                closeDiscardingQueue(additionalDiscardedFrames: 1)
                return
            }

        case .screen(
            let surfaceId,
            let streamIdentity,
            let revision,
            let recoveryText,
            _
        ):
            let terminalIdentity = WebSocketTerminalIdentity(
                surfaceId: surfaceId,
                streamIdentity: streamIdentity
            )
            if pendingRetirement == terminalIdentity {
                metrics.staleTerminalFrames += 1
                return
            }
            if var revisionState = terminalRevisionStates[surfaceId] {
                guard revisionState.accept(
                    streamIdentity: streamIdentity,
                    revision: revision
                ) else {
                    metrics.staleTerminalFrames += 1
                    return
                }
                terminalRevisionStates[surfaceId] = revisionState
            } else {
                guard terminalRevisionStates.count < maximumQueuedFrames else {
                    closeDiscardingQueue(additionalDiscardedFrames: 1)
                    return
                }
                terminalRevisionStates[surfaceId] = WebSocketTerminalRevisionState(
                    streamIdentity: streamIdentity,
                    revision: revision
                )
                metrics.maximumTerminalRevisionStates = max(
                    metrics.maximumTerminalRevisionStates,
                    terminalRevisionStates.count
                )
            }

            let matchingIndices = queue.indices.filter { index in
                guard case .screen(let queuedSurfaceId, _, _, _, _) = queue[index].kind else {
                    return false
                }
                return queuedSurfaceId == surfaceId
            }
            if matchingIndices.isEmpty {
                guard appendWithinBound(entry) else {
                    closeDiscardingQueue(additionalDiscardedFrames: 1)
                    return
                }
            } else {
                let retained = queue.enumerated().compactMap { index, queued in
                    matchingIndices.contains(index) ? nil : queued
                }
                var removedBytes = 0
                for index in matchingIndices {
                    let (nextRemovedBytes, overflow) = removedBytes.addingReportingOverflow(
                        queue[index].retainedFramedByteCount
                    )
                    guard !overflow else {
                        closeDiscardingQueue(additionalDiscardedFrames: 1)
                        return
                    }
                    removedBytes = nextRemovedBytes
                }
                let replacement: WebSocketQueuedOutput
                do {
                    replacement = try WebSocketQueuedOutput(
                        text: recoveryText,
                        kind: .screen(
                            surfaceId: surfaceId,
                            streamIdentity: streamIdentity,
                            revision: revision,
                            recoveryText: recoveryText,
                            frameKind: .full
                        )
                    )
                } catch {
                    metrics.encodingFailures += 1
                    closeDiscardingQueue(additionalDiscardedFrames: 1)
                    return
                }
                let (retainedBytes, underflow) = queuedBytes.subtractingReportingOverflow(
                    removedBytes
                )
                guard !underflow, retainedBytes >= 0 else {
                    closeDiscardingQueue(additionalDiscardedFrames: 1)
                    return
                }
                let (candidateBytes, overflow) = retainedBytes.addingReportingOverflow(
                    replacement.retainedFramedByteCount
                )
                guard !overflow,
                      retained.count + 1 <= maximumQueuedFrames,
                      candidateBytes <= maximumQueuedBytes
                else {
                    closeDiscardingQueue(additionalDiscardedFrames: 1)
                    return
                }
                queue = retained
                queue.append(replacement)
                queuedBytes = candidateBytes
                metrics.coalescedTerminalFrames += matchingIndices.count
                recordQueueHighWater()
            }
        }
        drain()
    }

    private func appendWithinBound(_ entry: WebSocketQueuedOutput) -> Bool {
        let (candidateBytes, overflow) = queuedBytes.addingReportingOverflow(
            entry.retainedFramedByteCount
        )
        guard !overflow,
              queue.count < maximumQueuedFrames,
              candidateBytes <= maximumQueuedBytes
        else { return false }
        queue.append(entry)
        queuedBytes = candidateBytes
        recordQueueHighWater()
        return true
    }

    private func recordQueueHighWater() {
        metrics.maximumQueuedBytes = max(metrics.maximumQueuedBytes, queuedBytes)
        metrics.maximumQueuedFrames = max(metrics.maximumQueuedFrames, queue.count)
    }

    private func drain() {
        guard !isClosed,
              !hasWriteInFlight,
              channel.isActive,
              channel.isWritable,
              !queue.isEmpty
        else { return }

        let entry = queue.removeFirst()
        let (remainingBytes, underflow) = queuedBytes.subtractingReportingOverflow(
            entry.retainedFramedByteCount
        )
        guard !underflow, remainingBytes >= 0 else {
            closeDiscardingQueue(additionalDiscardedFrames: 1)
            return
        }
        queuedBytes = remainingBytes
        hasWriteInFlight = true
        metrics.writesStarted += 1
        metrics.maximumInFlightWrites = max(metrics.maximumInFlightWrites, 1)
        switch entry.kind {
        case .critical:
            inFlightTerminalIdentity = nil
            metrics.criticalWrites += 1
        case .screen(let surfaceId, let streamIdentity, _, _, let frameKind):
            inFlightTerminalIdentity = WebSocketTerminalIdentity(
                surfaceId: surfaceId,
                streamIdentity: streamIdentity
            )
            switch frameKind {
            case .critical:
                metrics.criticalWrites += 1
            case .full:
                metrics.fullWrites += 1
            case .diff:
                metrics.diffWrites += 1
            case .checksum:
                metrics.checksumWrites += 1
            }
        }

        channel.writeText(entry.text).whenComplete { [weak self] result in
            self?.writeCompleted(result)
        }
    }

    private func writeCompleted(_ result: Result<Void, Error>) {
        precondition(channel.eventLoop.inEventLoop)
        guard !isClosed else { return }
        let completedTerminalIdentity = inFlightTerminalIdentity
        inFlightTerminalIdentity = nil
        hasWriteInFlight = false
        if let completedTerminalIdentity,
           pendingRetirement == completedTerminalIdentity
        {
            clearRevisionState(completedTerminalIdentity)
            pendingRetirement = nil
        }
        switch result {
        case .success:
            metrics.writesCompleted += 1
            drain()
        case .failure:
            metrics.writeFailures += 1
            closeDiscardingQueue()
        }
    }

    private func closeDiscardingQueue(additionalDiscardedFrames: Int = 0) {
        guard !isClosed else { return }
        isClosed = true
        metrics.discardedFrames += queue.count + additionalDiscardedFrames
        queue.removeAll(keepingCapacity: false)
        terminalRevisionStates.removeAll(keepingCapacity: false)
        pendingRetirement = nil
        inFlightTerminalIdentity = nil
        queuedBytes = 0
        hasWriteInFlight = false
        if channel.isActive {
            channel.close()
        }
    }

    private func clearRevisionState(_ identity: WebSocketTerminalIdentity) {
        guard terminalRevisionStates[identity.surfaceId]?.streamIdentity
                == identity.streamIdentity
        else { return }
        terminalRevisionStates[identity.surfaceId] = nil
    }

    private static func encode(_ frame: PushFrame) throws -> String {
        let data = try SharedKitJSON.deterministicEncoder.encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WebSocketOutputEncodingError.invalidUTF8
        }
        return text
    }

    private static func frameKind(_ frame: PushFrame) -> WebSocketOutputFrameKind {
        switch frame {
        case .screenFull:
            return .full
        case .screenDiff:
            return .diff
        case .screenChecksum:
            return .checksum
        case .event, .ping, .pong:
            return .critical
        }
    }
}
