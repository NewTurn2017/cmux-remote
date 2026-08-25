import Foundation

/// Awaits exact test events with a bounded fail-safe deadline and no polling.
actor RelayServerBoundedStreamProbe<Element: Sendable> {
    private var buffered: [Element] = []
    private var waiters: [UUID: CheckedContinuation<Element, Error>] = [:]
    private var waiterOrder: [UUID] = []
    private var consumerTask: Task<Void, Never>?

    private init() {}

    static func make(stream: AsyncStream<Element>) async -> RelayServerBoundedStreamProbe<Element> {
        let probe = RelayServerBoundedStreamProbe<Element>()
        await probe.start(stream: stream)
        return probe
    }

    deinit {
        consumerTask?.cancel()
    }

    func next() async throws -> Element {
        try await withThrowingTaskGroup(of: Element.self) { group in
            group.addTask { try await self.nextValue() }
            group.addTask {
                // This deadline only fails a hung test; exact stream events drive synchronization.
                try await ContinuousClock().sleep(for: .seconds(2))
                throw RelayServerBoundedStreamError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw RelayServerBoundedStreamError.ended
            }
            return result
        }
    }

    private func start(stream: AsyncStream<Element>) {
        consumerTask = Task { [weak self] in
            for await element in stream {
                guard let self else { return }
                await self.receive(element)
            }
        }
    }

    private func receive(_ element: Element) {
        if let id = waiterOrder.first {
            waiterOrder.removeFirst()
            waiters.removeValue(forKey: id)?.resume(returning: element)
        } else {
            buffered.append(element)
        }
    }

    private func nextValue() async throws -> Element {
        if !buffered.isEmpty {
            return buffered.removeFirst()
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = continuation
                waiterOrder.append(id)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        waiterOrder.removeAll { $0 == id }
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
