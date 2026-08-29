import Foundation

typealias AttachmentCancellationDeadline = @Sendable () async throws -> Void

enum AttachmentCancellationBranch: Hashable, Sendable {
    case rpc
    case deadline
}

actor AttachmentCancellationSignal {
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if completed { return }
        await withCheckedContinuation { continuation in
            if completed {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func complete() {
        guard !completed else { return }
        completed = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

struct AttachmentCancellationOperation: Sendable {
    let rpcTask: Task<Void, Never>
    let deadlineTask: Task<Void, Never>
    var unfinished: Set<AttachmentCancellationBranch>

    func cancel() {
        rpcTask.cancel()
        deadlineTask.cancel()
    }
}
