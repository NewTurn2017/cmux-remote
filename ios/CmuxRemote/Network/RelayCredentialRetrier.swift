import Foundation

protocol AuthCredentialPreparing: Sendable {
    func prepareCredentials() async throws -> AuthCredentials
}

extension AuthClient: AuthCredentialPreparing {}

/// Retries only failures that can recover without user input. Authorization,
/// configuration, and protocol errors remain terminal and visible.
struct RelayCredentialRetrier {
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let sleep: Sleep
    private let maximumDelay: TimeInterval

    init(
        maximumDelay: TimeInterval = 30,
        sleep: @escaping Sleep = { delay in
            try await Task.sleep(for: .seconds(delay))
        }
    ) {
        self.maximumDelay = maximumDelay
        self.sleep = sleep
    }

    @MainActor
    func prepare(
        using auth: any AuthCredentialPreparing,
        while shouldContinue: @MainActor () -> Bool,
        onWaiting: @MainActor (TimeInterval) -> Void
    ) async throws -> AuthCredentials {
        var transportDelay: TimeInterval = 1
        while shouldContinue() {
            do {
                let credentials = try await auth.prepareCredentials()
                guard shouldContinue() else { throw CancellationError() }
                return credentials
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard shouldContinue(), let delay = retryDelay(
                    for: error,
                    transportDelay: transportDelay
                ) else {
                    throw error
                }
                onWaiting(delay)
                try await sleep(delay)
                transportDelay = min(transportDelay * 2, maximumDelay)
            }
        }
        throw CancellationError()
    }

    static func isRetryable(_ error: Error) -> Bool {
        if case AuthError.relayUnavailable = error { return true }
        if case AuthError.transport = error { return true }
        if error is URLError { return true }
        return (error as NSError).domain == NSURLErrorDomain
    }

    private func retryDelay(
        for error: Error,
        transportDelay: TimeInterval
    ) -> TimeInterval? {
        if case let AuthError.relayUnavailable(_, retryAfter) = error {
            return min(max(retryAfter ?? transportDelay, 0), maximumDelay)
        }
        if Self.isRetryable(error) { return transportDelay }
        return nil
    }
}
