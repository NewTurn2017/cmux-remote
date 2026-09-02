import Foundation
@testable import CmuxRemote

actor ScriptedCredentialPreparer: AuthCredentialPreparing {
    enum Step {
        case result(AuthCredentials)
        case failure(Error)
    }

    private var steps: [Step]
    private var callCount = 0

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func prepareCredentials() async throws -> AuthCredentials {
        callCount += 1
        guard !steps.isEmpty else { throw AuthError.invalidRelayResponse }
        switch steps.removeFirst() {
        case .result(let credentials): return credentials
        case .failure(let error): throw error
        }
    }

    func calls() -> Int { callCount }
}

actor CredentialRetryGate {
    private let waitsStream: AsyncStream<TimeInterval>
    private let waitsContinuation: AsyncStream<TimeInterval>.Continuation
    private var releases: [CheckedContinuation<Void, Never>] = []

    init() {
        (waitsStream, waitsContinuation) = AsyncStream.makeStream(of: TimeInterval.self)
    }

    func waits() -> AsyncStream<TimeInterval> { waitsStream }

    func wait(_ delay: TimeInterval) async throws {
        waitsContinuation.yield(delay)
        await withCheckedContinuation { releases.append($0) }
        try Task.checkCancellation()
    }

    func releaseNext() {
        guard !releases.isEmpty else { return }
        releases.removeFirst().resume()
    }
}
