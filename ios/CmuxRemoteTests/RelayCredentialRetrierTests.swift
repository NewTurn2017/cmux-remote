import Foundation
import Testing
@testable import CmuxRemote

@Suite(.timeLimit(.minutes(1)))
struct RelayCredentialRetrierTests {
    @Test
    @MainActor
    func retriesServerUnavailableThenReturnsCredentials() async throws {
        let credentials = AuthCredentials(deviceId: "d1", bearer: "token")
        let auth = ScriptedCredentialPreparer([
            .failure(AuthError.relayUnavailable(status: 503, retryAfter: 7)),
            .result(credentials),
        ])
        let gate = CredentialRetryGate()
        let retrier = RelayCredentialRetrier(sleep: { try await gate.wait($0) })
        let waits = await gate.waits()
        var waitIterator = waits.makeAsyncIterator()

        let task = Task { @MainActor in
            try await retrier.prepare(using: auth, while: { true }, onWaiting: { _ in })
        }
        #expect(await waitIterator.next() == 7)
        await gate.releaseNext()

        #expect(try await task.value == credentials)
        #expect(await auth.calls() == 2)
    }

    @Test
    @MainActor
    func retriesTransportFailureWithExponentialBackoff() async throws {
        let credentials = AuthCredentials(deviceId: "d1", bearer: "token")
        let auth = ScriptedCredentialPreparer([
            .failure(URLError(.notConnectedToInternet)),
            .failure(URLError(.timedOut)),
            .result(credentials),
        ])
        let gate = CredentialRetryGate()
        let retrier = RelayCredentialRetrier(sleep: { try await gate.wait($0) })
        let waits = await gate.waits()
        var waitIterator = waits.makeAsyncIterator()
        let task = Task { @MainActor in
            try await retrier.prepare(using: auth, while: { true }, onWaiting: { _ in })
        }

        #expect(await waitIterator.next() == 1)
        await gate.releaseNext()
        #expect(await waitIterator.next() == 2)
        await gate.releaseNext()
        #expect(try await task.value == credentials)
    }

    @Test
    @MainActor
    func policyDenialDoesNotRetry() async {
        let auth = ScriptedCredentialPreparer([
            .failure(AuthError.registrationDenied),
        ])
        let retrier = RelayCredentialRetrier(sleep: { _ in
            Issue.record("terminal failure must not sleep")
        })

        await #expect(throws: AuthError.registrationDenied) {
            try await retrier.prepare(using: auth, while: { true }, onWaiting: { _ in })
        }
        #expect(await auth.calls() == 1)
    }

    @Test
    @MainActor
    func cancellationDuringWaitStopsRetry() async {
        let auth = ScriptedCredentialPreparer([
            .failure(URLError(.timedOut)),
            .result(.init(deviceId: "d1", bearer: "token")),
        ])
        let gate = CredentialRetryGate()
        let retrier = RelayCredentialRetrier(sleep: { try await gate.wait($0) })
        let waits = await gate.waits()
        var waitIterator = waits.makeAsyncIterator()
        let task = Task { @MainActor in
            try await retrier.prepare(
                using: auth,
                while: { !Task.isCancelled },
                onWaiting: { _ in }
            )
        }

        #expect(await waitIterator.next() == 1)
        task.cancel()
        await gate.releaseNext()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await auth.calls() == 1)
    }
}
