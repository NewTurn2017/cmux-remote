import Testing
@testable import CMUXClient

@Suite("CMUXReadinessTests")
struct CMUXReadinessTests {
    @Test func readinessTimeoutCancelsClientWaiterAndLaterReadyStillSucceeds() async throws {
        let (installationEvents, installationContinuation) = AsyncStream<Void>.makeStream()
        let fixture = try await MTELGCmuxFixture.make(
            awaitReadiness: false,
            inboundInstallationGate: { operation in
                for await _ in installationEvents {
                    try await operation()
                    return
                }
                throw CancellationError()
            }
        )

        do {
            try await MTELGCmuxFixture.awaitReadiness(timeout: .milliseconds(20)) {
                try await fixture.client.awaitReady()
            }
            Issue.record("no-event readiness unexpectedly completed")
        } catch let error as MTELGCmuxFixture.ReadinessError {
            print("readinessTimeout=true error=\(error)")
            #expect(error == .timeout)
        } catch {
            Issue.record("expected exact fixture timeout, got \(error)")
        }

        installationContinuation.yield(())
        installationContinuation.finish()
        try await MTELGCmuxFixture.awaitReadiness(timeout: .seconds(1)) {
            try await fixture.client.awaitReady()
        }
        print("cancelledWaiterCleaned=true readyAfterEvent=true")
        await fixture.shutdown()
    }

    @Test func successfulReadinessUsesBoundedExactEvent() async throws {
        let fixture = try await MTELGCmuxFixture.make()
        print("successfulBoundedReady=true")
        await fixture.shutdown()
    }

    @Test func inboundHandlerInstallationFailureNeverReportsReady() async throws {
        let fixture = try await MTELGCmuxFixture.make(
            closeClientBeforeInboundInstallation: true,
            awaitReadiness: false
        )

        for attempt in 1...2 {
            do {
                try await fixture.client.awaitReady()
                Issue.record("attempt \(attempt) unexpectedly reported ready")
            } catch let error as CMUXClientError {
                print("failedInstallAttempt=\(attempt) readinessError=\(error)")
                #expect(error == .inboundHandlerInstallationFailed)
            } catch {
                Issue.record("expected exact CMUXClientError, got \(error)")
            }
        }

        await fixture.shutdown()
    }
}
