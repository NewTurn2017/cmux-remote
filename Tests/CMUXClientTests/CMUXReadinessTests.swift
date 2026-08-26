import Foundation
import NIOCore
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

    @Test func requestLineTimeoutCancelsWaiterAndUnixFixtureTeardownIsBounded() async throws {
        let fixture = try await MTELGCmuxFixture.makeUnixSocket(
            requestTimeout: .seconds(1),
            setupTimeout: .seconds(1)
        )
        let socketDirectory = try #require(fixture.socketDirectory)
        let clock = ContinuousClock()
        let requestStart = clock.now

        do {
            _ = try await fixture.awaitRequestLine(timeout: 20_000_000)
            Issue.record("request-less fixture unexpectedly produced a line")
        } catch let error as MTELGCmuxFixture.FixtureError {
            #expect(error == .requestTimeout)
        }

        #expect(requestStart.duration(to: clock.now) < .seconds(1))
        #expect(fixture.serverInbox.pendingLineWaiterCount == 0)

        let shutdownStart = clock.now
        try await fixture.shutdown(timeout: .seconds(1))
        #expect(shutdownStart.duration(to: clock.now) < .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: socketDirectory.path))
    }

    @Test func fastSetupCancelsBindAndConnectDeadlines() async throws {
        let scheduler = TrackingFixtureDeadlineScheduler()
        let fixture = try await MTELGCmuxFixture.makeUnixSocket(
            deadlineScheduler: scheduler
        )

        #expect(scheduler.scheduledCount == 2)
        #expect(scheduler.cancelledCount == 2)
        await fixture.shutdown()
    }

    @Test func fastShutdownCancelsDeadlineAndRemovesSocketAfterCompletion() async throws {
        let scheduler = TrackingFixtureDeadlineScheduler()
        let fixture = try await MTELGCmuxFixture.makeUnixSocket()
        let socketDirectory = try #require(fixture.socketDirectory)

        try await fixture.shutdown(timeout: .seconds(1), scheduler: scheduler)

        #expect(fixture.cleanupState == .completed)
        #expect(scheduler.scheduledCount == 1)
        #expect(scheduler.cancelledCount == 1)
        #expect(!FileManager.default.fileExists(atPath: socketDirectory.path))
    }

    @Test func blockedShutdownFinalizationIsSingleFlightForConcurrentCallers() async throws {
        let gate = FixtureOperationGate()
        let scheduler = ImmediateFixtureDeadlineScheduler(firingSchedule: 1)
        let (registrationEvents, registrationContinuation) = AsyncStream<Void>.makeStream()
        let fixture = try await MTELGCmuxFixture.makeUnixSocket(
            shutdownGate: gate,
            shutdownCompletionWaiterRegistered: {
                registrationContinuation.yield(())
            }
        )
        let socketDirectory = try #require(fixture.socketDirectory)

        do {
            try await fixture.shutdown(timeout: .seconds(1), scheduler: scheduler)
            Issue.record("blocked shutdown unexpectedly reported completion")
        } catch let error as MTELGCmuxFixture.FixtureError {
            #expect(error == .shutdownTimeout)
        }

        #expect(fixture.cleanupState == .timedOut)
        #expect(gate.isHoldingOperation)
        #expect(FileManager.default.fileExists(atPath: socketDirectory.path))

        async let firstFinish: Void = fixture.finishShutdown()
        async let secondFinish: Void = fixture.finishShutdown()
        async let nonthrowingShutdown: Void = fixture.shutdown()

        do {
            try await MTELGCmuxFixture.awaitReadiness(timeout: .seconds(1)) {
                var registrations = registrationEvents.makeAsyncIterator()
                for _ in 0..<3 {
                    guard await registrations.next() != nil else {
                        throw CancellationError()
                    }
                }
            }
        } catch {
            gate.release()
            _ = try? await (firstFinish, secondFinish)
            await nonthrowingShutdown
            throw error
        }

        gate.release()
        _ = try await (firstFinish, secondFinish)
        await nonthrowingShutdown
        registrationContinuation.finish()

        #expect(fixture.cleanupState == .completed)
        #expect(!FileManager.default.fileExists(atPath: socketDirectory.path))
    }

    @Test(arguments: [1, 2])
    func setupTimeoutJoinsBindOrConnectAndCleansSocketDirectory(
        firingSchedule: Int
    ) async throws {
        let scheduler = ImmediateFixtureDeadlineScheduler(firingSchedule: firingSchedule)
        let socketDirectory = URL(
            fileURLWithPath: "/tmp/cmux-setup-timeout-\(UUID().uuidString.prefix(12))",
            isDirectory: true
        )

        do {
            _ = try await MTELGCmuxFixture.makeUnixSocket(
                setupTimeout: .seconds(1),
                deadlineScheduler: scheduler,
                socketDirectory: socketDirectory
            )
            Issue.record("setup stage \(firingSchedule) unexpectedly succeeded")
        } catch let error as MTELGCmuxFixture.FixtureError {
            #expect(error == .setupTimeout)
        }

        #expect(scheduler.scheduledCount >= firingSchedule)
        #expect(!FileManager.default.fileExists(atPath: socketDirectory.path))
    }

    @Test func socketDirectoryFailureOccursBeforeAnyDeadlineOrEventLoopWork() async {
        let scheduler = TrackingFixtureDeadlineScheduler()
        let missingParent = URL(
            fileURLWithPath: "/tmp/cmux-missing-parent-\(UUID().uuidString.prefix(12))",
            isDirectory: true
        )
        let socketDirectory = missingParent.appendingPathComponent("child", isDirectory: true)

        do {
            _ = try await MTELGCmuxFixture.makeUnixSocket(
                deadlineScheduler: scheduler,
                socketDirectory: socketDirectory
            )
            Issue.record("mkdir with a missing parent unexpectedly succeeded")
        } catch {
            #expect(scheduler.scheduledCount == 0)
            #expect(!FileManager.default.fileExists(atPath: missingParent.path))
        }
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

private final class TrackingFixtureDeadlineScheduler: FixtureDeadlineScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [FixtureDeadlineHandle] = []

    var scheduledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return handles.count
    }

    var cancelledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return handles.filter(\.isCancelled).count
    }

    func schedule(
        after timeout: Duration,
        action: @escaping @Sendable () -> Void
    ) -> FixtureDeadlineHandle {
        _ = timeout
        _ = action
        let handle = FixtureDeadlineHandle()
        lock.lock()
        handles.append(handle)
        lock.unlock()
        return handle
    }
}

private final class ImmediateFixtureDeadlineScheduler: FixtureDeadlineScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private let firingSchedule: Int
    private var schedules = 0

    init(firingSchedule: Int) {
        self.firingSchedule = firingSchedule
    }

    var scheduledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return schedules
    }

    func schedule(
        after timeout: Duration,
        action: @escaping @Sendable () -> Void
    ) -> FixtureDeadlineHandle {
        _ = timeout
        let handle = FixtureDeadlineHandle()
        lock.lock()
        schedules += 1
        let shouldFire = schedules == firingSchedule
        lock.unlock()
        if shouldFire { handle.fire(action) }
        return handle
    }
}
