import CMUXClient
import Foundation
@testable import RelayCore

actor ScriptedTerminalSourceReader: TerminalSourceReader {
    private var steps: [ScriptedTerminalSourceStep]
    private var suspendedReads: [UUID: ScriptedSuspendedTerminalRead] = [:]
    private var suspendedOrder: [UUID] = []
    private var readCounts: [String: Int] = [:]
    private var inFlight = 0
    private var maximumInFlight = 0
    private var releases: [String: Int] = [:]
    private var cancellations = 0
    private var shouldSuspendReleases = false
    private var releaseWaiters: [ScriptedTerminalSourceReleaseWaiter] = []
    private var eventContinuation: AsyncStream<ScriptedTerminalReadEvent>.Continuation?
    private var cancellationContinuation: AsyncStream<Int>.Continuation?
    private var releaseContinuation: AsyncStream<Int>.Continuation?

    init(steps: [ScriptedTerminalSourceStep]) {
        self.steps = steps
    }

    func readEvents() -> AsyncStream<ScriptedTerminalReadEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            eventContinuation = continuation
        }
    }

    func cancellationEvents() -> AsyncStream<Int> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            cancellationContinuation = continuation
        }
    }

    func releaseEvents() -> AsyncStream<Int> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            releaseContinuation = continuation
        }
    }

    func setSuspendsReleases(_ shouldSuspend: Bool) {
        shouldSuspendReleases = shouldSuspend
    }

    func append(_ step: ScriptedTerminalSourceStep) {
        steps.append(step)
    }

    func readTerminal(
        workspaceId: String,
        surfaceId: String,
        lines: Int
    ) async throws -> CMUXTerminalReadOutcome {
        let step = steps.isEmpty ? .failure("unexpected unscripted read") : steps.removeFirst()
        readCounts[surfaceId, default: 0] += 1
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        eventContinuation?.yield(ScriptedTerminalReadEvent(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            readCount: readCounts[surfaceId, default: 0],
            inFlight: inFlight
        ))
        defer { inFlight -= 1 }

        switch step {
        case .immediate(let outcome):
            return outcome
        case .failure(let description):
            throw ScriptedTerminalSourceError.failure(description)
        case .suspended(let outcome):
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    suspendedReads[id] = ScriptedSuspendedTerminalRead(
                        outcome: outcome,
                        continuation: continuation
                    )
                    suspendedOrder.append(id)
                }
            } onCancel: {
                Task { await self.cancelSuspendedRead(id: id) }
            }
        }
    }

    func releaseTerminalSource(workspaceId: String, surfaceId: String) async throws {
        releases[surfaceId, default: 0] += 1
        releaseContinuation?.yield(releases[surfaceId, default: 0])
        guard shouldSuspendReleases else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(ScriptedTerminalSourceReleaseWaiter(
                continuation: continuation
            ))
        }
    }

    func resetTerminalSources() async throws {}

    func completeNextRelease() {
        guard !releaseWaiters.isEmpty else { return }
        releaseWaiters.removeFirst().continuation.resume()
    }

    func completeNextSuspendedRead() {
        guard let id = suspendedOrder.first else { return }
        suspendedOrder.removeFirst()
        guard let suspended = suspendedReads.removeValue(forKey: id) else { return }
        suspended.continuation.resume(returning: suspended.outcome)
    }

    func readCount(surfaceId: String) -> Int {
        readCounts[surfaceId, default: 0]
    }

    func maximumInFlightReadCount() -> Int {
        maximumInFlight
    }

    func inFlightReadCount() -> Int {
        inFlight
    }

    func releaseCount(surfaceId: String) -> Int {
        releases[surfaceId, default: 0]
    }

    func cancellationCount() -> Int {
        cancellations
    }

    private func cancelSuspendedRead(id: UUID) {
        guard let suspended = suspendedReads.removeValue(forKey: id) else { return }
        suspendedOrder.removeAll { $0 == id }
        cancellations += 1
        cancellationContinuation?.yield(cancellations)
        suspended.continuation.resume(throwing: CancellationError())
    }
}
