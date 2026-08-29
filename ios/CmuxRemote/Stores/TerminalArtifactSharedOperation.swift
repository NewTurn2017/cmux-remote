import Foundation

enum TerminalArtifactOperationKind: Sendable {
    case scan
    case thumbnail
    case full
    case viewer
}

actor TerminalArtifactOperationCompletion<Value: Sendable> {
    private var result: Result<Value, any Error>?
    private var waiters: [UUID: CheckedContinuation<Value, any Error>] = [:]

    func value(waiter: UUID) async throws -> Value {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            if let result {
                continuation.resume(with: result)
            } else {
                waiters[waiter] = continuation
            }
        }
    }

    func cancel(waiter: UUID, error: any Error = CancellationError()) {
        waiters.removeValue(forKey: waiter)?.resume(throwing: error)
    }

    func finish(_ result: Result<Value, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        let current = waiters
        waiters.removeAll()
        for continuation in current.values { continuation.resume(with: result) }
    }

    func retire() {
        finish(.failure(TerminalArtifactStoreError.staleIdentity))
    }
}

struct TerminalArtifactSharedOperation<Value: Sendable>: Sendable {
    let id: UUID
    let kind: TerminalArtifactOperationKind
    let task: Task<Void, Never>
    let completion: TerminalArtifactOperationCompletion<Value>
    var waiters: Set<UUID>
}

struct TerminalArtifactRetiredOperation: Sendable {
    let id: UUID
    let kind: TerminalArtifactOperationKind
    let task: Task<Void, Never>
}
