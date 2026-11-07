import Foundation

/// Result of work that ran against a deadline.
enum BoundedRelayWorkOutcome<Value: Sendable>: Sendable {
    case finished(Value)
    case timedOut
}

/// Runs relay-owned work that can block in the kernel without holding the WebSocket FIFO.
///
/// Every inbound frame on one WebSocket runs in strict FIFO order, and relay-owned file
/// operations can block uninterruptibly: a pending macOS privacy prompt for `~/Downloads`
/// holds `openat` until someone answers it on the Mac. Structured concurrency cannot
/// abandon such a child, because a task group waits for every child before returning.
/// This helper runs the work in an unstructured task and answers at the deadline instead,
/// so the frames queued behind it still run. Abandoned work keeps running and its result
/// is discarded.
enum BoundedRelayWork {
    /// Deadline for one relay-owned file RPC. It stays under the phone's 10 second RPC
    /// timeout so later frames still answer in time.
    static let defaultTimeout: Duration = .seconds(4)

    static func run<Value: Sendable>(
        timeout: Duration,
        _ operation: @escaping @Sendable () async -> Value
    ) async -> BoundedRelayWorkOutcome<Value> {
        let gate = ResumeOnce<BoundedRelayWorkOutcome<Value>>()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            let deadline = Task {
                // The deadline itself, not a polling loop.
                try? await Task.sleep(for: timeout)
                gate.resume(with: .timedOut)
            }
            Task {
                let value = await operation()
                deadline.cancel()
                gate.resume(with: .finished(value))
            }
        }
    }

    /// Runs synchronous, possibly blocking file work on a GCD queue.
    ///
    /// A blocked syscall on Swift's cooperative pool holds one of its few threads. GCD can
    /// add threads, so repeated blocked writes cannot starve the relay's async work.
    static func offCooperativePool<Value: Sendable>(
        _ work: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever side finishes first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(with value: Value) {
        let pending: CheckedContinuation<Value, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
