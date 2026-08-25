import CMUXClient
import Testing
import SharedKit
@testable import RelayCore

@Suite("SurfaceRenderHubTests")
struct SurfaceRenderHubTests {
    @Test func twoSubscribersShareOneSourceReadPerScheduledTick() async throws {
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.legacyUpdate(text: "shared")),
        ])
        let clock = ManualSurfaceRenderClock()
        let sleepProbe = await BoundedAsyncStreamProbe.make(stream: clock.requests())
        let firstFull = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let secondFull = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let firstFullProbe = await BoundedAsyncStreamProbe.make(stream: firstFull.stream)
        let secondFullProbe = await BoundedAsyncStreamProbe.make(stream: secondFull.stream)
        let manager = SessionManager(
            terminalReader: source,
            defaultFps: 15,
            idleFps: 5,
            clockFactory: { clock }
        )
        let first = await manager.attach(deviceId: "first") { frame in
            if case .screenFull(let full) = frame {
                firstFull.continuation.yield(full.rev)
            }
        }
        let second = await manager.attach(deviceId: "second") { frame in
            if case .screenFull(let full) = frame {
                secondFull.continuation.yield(full.rev)
            }
        }

        try await first.subscribe(workspaceId: "workspace", surfaceId: "surface", lines: 120)
        try await second.subscribe(workspaceId: "workspace", surfaceId: "surface", lines: 120)
        let request = try await sleepProbe.next()
        #expect(Self.approximatelyEqual(request.seconds, 1.0 / 15.0))

        await clock.advance(by: request.seconds)
        #expect(try await firstFullProbe.next() == 1)
        #expect(try await secondFullProbe.next() == 1)
        #expect(await source.readCount(surfaceId: "surface") == 1)
        #expect(await manager.activeRenderHubCount == 1)

        await manager.detach(session: first)
        await manager.detach(session: second)
        #expect(await source.releaseCount(surfaceId: "surface") == 1)
        #expect(await manager.activeRenderHubCount == 0)
    }

    @Test func differentSurfacesHaveIsolatedActorsAndReads() async throws {
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.legacyUpdate(text: "alpha")),
            .immediate(Self.legacyUpdate(text: "beta")),
        ])
        let registry = SurfaceRenderHubRegistry(
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5),
            clockFactory: { ManualSurfaceRenderClock() }
        )
        let firstSubscription = try await registry.subscribe(
            workspaceId: "workspace",
            surfaceId: "alpha",
            lines: 120,
            onDiff: { _, _ in },
            onChecksum: { _, _ in }
        )
        let secondSubscription = try await registry.subscribe(
            workspaceId: "workspace",
            surfaceId: "beta",
            lines: 120,
            onDiff: { _, _ in },
            onChecksum: { _, _ in }
        )
        let first = try #require(await registry.hub(surfaceId: "alpha"))
        let second = try #require(await registry.hub(surfaceId: "beta"))

        await first.tick()
        await second.tick()

        #expect(ObjectIdentifier(first) != ObjectIdentifier(second))
        #expect(await source.readCount(surfaceId: "alpha") == 1)
        #expect(await source.readCount(surfaceId: "beta") == 1)
        #expect(await first.currentScreen?.rows == ["alpha"])
        #expect(await second.currentScreen?.rows == ["beta"])
        await registry.unsubscribe(firstSubscription)
        await registry.unsubscribe(secondSubscription)
    }

    @Test func lateSubscriberReceivesCurrentSnapshotWithoutAnotherRead() async throws {
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.legacyUpdate(text: "current")),
        ])
        let lateDiff = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let lateDiffProbe = await BoundedAsyncStreamProbe.make(stream: lateDiff.stream)
        let hub = SurfaceRenderHub(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5),
            clock: ManualSurfaceRenderClock()
        )
        _ = try await hub.subscribe(onDiff: { _, _ in }, onChecksum: { _, _ in })
        await hub.tick()

        _ = try await hub.subscribe(
            onDiff: { _, operations in lateDiff.continuation.yield(operations.count) },
            onChecksum: { _, _ in }
        )

        #expect(try await lateDiffProbe.next() == 3)
        #expect(await source.readCount(surfaceId: "surface") == 1)
        #expect(await hub.metrics.fanoutDeliveries == 2)
        await hub.stop()
    }

    @Test func oneHundredBusyTicksCoalesceOneContinuationWithoutOverlap() async throws {
        let firstOutcome = Self.renderUpdate(epoch: Self.epochA, revision: 1, text: "first")
        let secondOutcome = Self.renderUpdate(epoch: Self.epochA, revision: 2, text: "second")
        let source = ScriptedTerminalSourceReader(steps: [
            .suspended(firstOutcome),
            .immediate(secondOutcome),
        ])
        let readProbe = await BoundedAsyncStreamProbe.make(stream: source.readEvents())
        let diff = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let diffProbe = await BoundedAsyncStreamProbe.make(stream: diff.stream)
        let clock = ManualSurfaceRenderClock()
        let hub = SurfaceRenderHub(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5),
            clock: clock
        )
        _ = try await hub.subscribe(
            onDiff: { revision, _ in diff.continuation.yield(revision) },
            onChecksum: { _, _ in }
        )

        let firstTick = Task { await hub.tick() }
        #expect(try await readProbe.next().readCount == 1)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<99 {
                group.addTask { await hub.tick() }
            }
        }

        #expect(await hub.hasPendingTick)
        #expect(await source.inFlightReadCount() == 1)
        #expect(await source.maximumInFlightReadCount() == 1)
        await clock.advance(by: 0.100)
        #expect(await clock.now > 1.0 / 15.0)
        #expect(await source.maximumInFlightReadCount() == 1)

        await source.completeNextSuspendedRead()
        await firstTick.value
        #expect(try await diffProbe.next() == 1)
        #expect(try await diffProbe.next() == 2)

        #expect(await source.readCount(surfaceId: "surface") == 2)
        #expect(await source.maximumInFlightReadCount() == 1)
        #expect(await hub.metrics.maximumInFlightReads == 1)
        #expect(await hub.metrics.coalescedTicks >= 99)
        #expect(await hub.currentScreen?.rows == ["second"])
        await hub.stop()
    }

    @Test func unchangedOutcomeSkipsDiffChecksumAndFanout() async throws {
        let identity = CMUXTerminalReplayIdentity(epoch: Self.epochA, revision: 1)
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.renderUpdate(identity: identity, text: "styled")),
            .immediate(.unchanged(identity)),
        ])
        let clock = ManualSurfaceRenderClock()
        let hub = SurfaceRenderHub(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5),
            clock: clock
        )
        _ = try await hub.subscribe(onDiff: { _, _ in }, onChecksum: { _, _ in })
        _ = try await hub.subscribe(onDiff: { _, _ in }, onChecksum: { _, _ in })

        await hub.tick()
        let deliveriesAfterUpdate = await hub.metrics.fanoutDeliveries
        await clock.advanceTimeOnly(by: 6)
        await hub.tick()

        #expect(deliveriesAfterUpdate == 2)
        #expect(await hub.metrics.fanoutDeliveries == deliveriesAfterUpdate)
        #expect(await hub.metrics.updatedOutcomes == 1)
        #expect(await hub.metrics.unchangedOutcomes == 1)
        #expect(await hub.currentScreen?.rows == ["styled"])
        await hub.stop()
    }

    @Test func finalReleaseRetiresGenerationBeforeConcurrentReacquire() async throws {
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.legacyUpdate(text: "old-generation")),
            .immediate(Self.legacyUpdate(text: "new-generation")),
        ])
        await source.setSuspendsReleases(true)
        let releaseProbe = await BoundedAsyncStreamProbe.make(stream: source.releaseEvents())
        let newDiff = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let newDiffProbe = await BoundedAsyncStreamProbe.make(stream: newDiff.stream)
        let registry = SurfaceRenderHubRegistry(
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5),
            maximumSurfaces: 1,
            clockFactory: { ManualSurfaceRenderClock() }
        )
        let oldSubscription = try await registry.subscribe(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            onDiff: { _, _ in },
            onChecksum: { _, _ in }
        )
        let oldHub = try #require(await registry.hub(surfaceId: "surface"))
        await oldHub.tick()

        let oldRelease = Task { await registry.unsubscribe(oldSubscription) }
        #expect(try await releaseProbe.next() == 1)
        #expect(await registry.activeHubCount == 0)
        #expect(await registry.cleanupTaskCount == 1)
        #expect(await registry.hub(surfaceId: "surface") == nil)

        let reacquire = Task {
            try await registry.subscribe(
                workspaceId: "workspace",
                surfaceId: "surface",
                lines: 120,
                onDiff: { revision, _ in newDiff.continuation.yield(revision) },
                onChecksum: { _, _ in }
            )
        }
        #expect(await registry.activeHubCount == 0)
        #expect(await registry.cleanupTaskCount == 1)

        await source.completeNextRelease()
        await oldRelease.value
        let newSubscription = try await reacquire.value
        let newHub = try #require(await registry.hub(surfaceId: "surface"))

        #expect(ObjectIdentifier(oldHub) != ObjectIdentifier(newHub))
        #expect(oldSubscription.generation != newSubscription.generation)
        #expect(await registry.generation(surfaceId: "surface") == newSubscription.generation)
        #expect(await oldHub.isStopped)
        #expect(await newHub.isStopped == false)
        #expect(await newHub.subscriberCount == 1)
        #expect(await source.releaseCount(surfaceId: "surface") == 1)
        print("generation.old=\(oldSubscription.generation) generation.new=\(newSubscription.generation) oldReleaseCount=1")
        await newHub.tick()
        #expect(try await newDiffProbe.next() == 1)
        #expect(await newHub.currentScreen?.rows == ["new-generation"])

        await source.setSuspendsReleases(false)
        await registry.unsubscribe(newSubscription)
        #expect(await source.releaseCount(surfaceId: "surface") == 2)
    }

    @Test func cancelledAcquireWaitingForRetirementCannotCreateOrphanLease() async throws {
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.legacyUpdate(text: "clean-generation")),
        ])
        await source.setSuspendsReleases(true)
        let releaseProbe = await BoundedAsyncStreamProbe.make(stream: source.releaseEvents())
        let acquisitionStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let acquisitionStartedProbe = await BoundedAsyncStreamProbe.make(
            stream: acquisitionStarted.stream
        )
        let cleanDiff = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let cleanDiffProbe = await BoundedAsyncStreamProbe.make(stream: cleanDiff.stream)
        let registry = SurfaceRenderHubRegistry(
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5),
            maximumSurfaces: 1,
            clockFactory: { ManualSurfaceRenderClock() }
        )
        let oldSubscription = try await registry.subscribe(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            onDiff: { _, _ in },
            onChecksum: { _, _ in }
        )

        let oldRelease = Task { await registry.unsubscribe(oldSubscription) }
        #expect(try await releaseProbe.next() == 1)
        let cancelledAcquire = Task { () throws -> SurfaceRenderSubscription in
            acquisitionStarted.continuation.yield()
            return try await registry.subscribe(
                workspaceId: "workspace",
                surfaceId: "surface",
                lines: 120,
                onDiff: { _, _ in },
                onChecksum: { _, _ in }
            )
        }
        _ = try await acquisitionStartedProbe.next()
        cancelledAcquire.cancel()
        await source.completeNextRelease()
        await source.setSuspendsReleases(false)
        await oldRelease.value

        var orphanedSubscription: SurfaceRenderSubscription?
        do {
            orphanedSubscription = try await cancelledAcquire.value
            Issue.record("cancelled acquisition returned a live lease")
        } catch is CancellationError {
        } catch {
            Issue.record("cancelled acquisition threw unexpected error: \(error)")
        }
        #expect(orphanedSubscription == nil)
        #expect(await registry.activeHubCount == 0)
        #expect(await registry.cleanupTaskCount == 0)
        #expect(await source.releaseCount(surfaceId: "surface") == 1)

        if let orphanedSubscription {
            await registry.unsubscribe(orphanedSubscription)
        }
        let cleanSubscription = try await registry.subscribe(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            onDiff: { revision, _ in cleanDiff.continuation.yield(revision) },
            onChecksum: { _, _ in }
        )
        let cleanHub = try #require(await registry.hub(surfaceId: "surface"))
        await cleanHub.tick()
        #expect(try await cleanDiffProbe.next() == 1)
        #expect(await cleanHub.isStopped == false)
        await registry.unsubscribe(cleanSubscription)
        #expect(await source.releaseCount(surfaceId: "surface") == 2)
    }

    @Test func cancellationAfterLeaseReservationRollsBackExactGeneration() async throws {
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.legacyUpdate(text: "clean-after-reservation")),
        ])
        let observer = SuspendingSurfaceRenderHubRegistryObserver(
            suspensionPoint: .reservation
        )
        let observationProbe = await BoundedAsyncStreamProbe.make(stream: observer.events())
        let registry = SurfaceRenderHubRegistry(
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5),
            maximumSurfaces: 1,
            clockFactory: { ManualSurfaceRenderClock() },
            observer: observer
        )
        let acquisition = Task {
            try await registry.subscribe(
                workspaceId: "workspace",
                surfaceId: "surface",
                lines: 120,
                onDiff: { _, _ in },
                onChecksum: { _, _ in }
            )
        }

        #expect(try await observationProbe.next() == .started("surface"))
        let reservedObservation = try await observationProbe.next()
        guard case .reserved(let reserved) = reservedObservation else {
            Issue.record("expected reservation observation")
            return
        }
        let reservedHub = try #require(await registry.hub(surfaceId: "surface"))
        #expect(await registry.activeHubCount == 1)
        #expect(await reservedHub.subscriberCount == 0)

        acquisition.cancel()
        await observer.resumeNext()
        do {
            _ = try await acquisition.value
            Issue.record("reservation-cancelled acquisition returned a lease")
        } catch is CancellationError {
        }

        #expect(await registry.activeHubCount == 0)
        #expect(await registry.cleanupTaskCount == 0)
        #expect(await reservedHub.isStopped)
        #expect(await source.releaseCount(surfaceId: "surface") == 1)
        #expect(reserved.generation == reservedHub.generation)

        await observer.setSuspensionPoint(.none)
        let clean = try await registry.subscribe(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            onDiff: { _, _ in },
            onChecksum: { _, _ in }
        )
        let cleanHub = try #require(await registry.hub(surfaceId: "surface"))
        #expect(clean.generation != reserved.generation)
        await cleanHub.tick()
        await registry.unsubscribe(clean)
        #expect(await source.releaseCount(surfaceId: "surface") == 2)
    }

    @Test func cancellationAfterHubRegistrationRemovesSubscriberAndGeneration() async throws {
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.legacyUpdate(text: "clean-after-registration")),
        ])
        let observer = SuspendingSurfaceRenderHubRegistryObserver(
            suspensionPoint: .registration
        )
        let observationProbe = await BoundedAsyncStreamProbe.make(stream: observer.events())
        let registry = SurfaceRenderHubRegistry(
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5),
            maximumSurfaces: 1,
            clockFactory: { ManualSurfaceRenderClock() },
            observer: observer
        )
        let acquisition = Task {
            try await registry.subscribe(
                workspaceId: "workspace",
                surfaceId: "surface",
                lines: 120,
                onDiff: { _, _ in },
                onChecksum: { _, _ in }
            )
        }

        #expect(try await observationProbe.next() == .started("surface"))
        _ = try await observationProbe.next()
        let registeredObservation = try await observationProbe.next()
        guard case .registered(let registered) = registeredObservation else {
            Issue.record("expected registration observation")
            return
        }
        let registeredHub = try #require(await registry.hub(surfaceId: "surface"))
        #expect(await registeredHub.subscriberCount == 1)

        acquisition.cancel()
        await observer.resumeNext()
        do {
            _ = try await acquisition.value
            Issue.record("registration-cancelled acquisition returned a lease")
        } catch is CancellationError {
        }

        #expect(await registry.activeHubCount == 0)
        #expect(await registry.cleanupTaskCount == 0)
        #expect(await registeredHub.subscriberCount == 0)
        #expect(await registeredHub.isStopped)
        #expect(await source.releaseCount(surfaceId: "surface") == 1)

        await observer.setSuspensionPoint(.none)
        let clean = try await registry.subscribe(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            onDiff: { _, _ in },
            onChecksum: { _, _ in }
        )
        #expect(clean.generation != registered.generation)
        let cleanHub = try #require(await registry.hub(surfaceId: "surface"))
        await cleanHub.tick()
        await registry.unsubscribe(clean)
        #expect(await source.releaseCount(surfaceId: "surface") == 2)
    }

    @Test func cancellationRollbackStressAcrossReservationAndRegistration() async throws {
        let iterationCount = 64
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.legacyUpdate(text: "clean-after-cancellation-stress")),
        ])
        let observer = SuspendingSurfaceRenderHubRegistryObserver(
            suspensionPoint: .reservation
        )
        let observationProbe = await BoundedAsyncStreamProbe.make(stream: observer.events())
        let registry = SurfaceRenderHubRegistry(
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5),
            maximumSurfaces: 1,
            clockFactory: { ManualSurfaceRenderClock() },
            observer: observer
        )

        for iteration in 0..<iterationCount {
            let point: SurfaceRenderHubRegistrySuspensionPoint = iteration.isMultiple(of: 2)
                ? .reservation
                : .registration
            await observer.setSuspensionPoint(point)
            let acquisition = Task {
                try await registry.subscribe(
                    workspaceId: "workspace",
                    surfaceId: "surface",
                    lines: 120,
                    onDiff: { _, _ in },
                    onChecksum: { _, _ in }
                )
            }

            #expect(try await observationProbe.next() == .started("surface"))
            let reservedObservation = try await observationProbe.next()
            guard case .reserved(let reserved) = reservedObservation else {
                Issue.record("expected stress reservation observation")
                return
            }
            if point == .registration {
                let registeredObservation = try await observationProbe.next()
                #expect(registeredObservation == .registered(reserved))
            }

            acquisition.cancel()
            await observer.resumeNext()
            do {
                _ = try await acquisition.value
                Issue.record("stress-cancelled acquisition returned a lease at \(iteration)")
            } catch is CancellationError {
            }

            #expect(await registry.activeHubCount == 0)
            #expect(await registry.cleanupTaskCount == 0)
            #expect(await source.releaseCount(surfaceId: "surface") == iteration + 1)
        }

        await observer.setSuspensionPoint(.none)
        let clean = try await registry.subscribe(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            onDiff: { _, _ in },
            onChecksum: { _, _ in }
        )
        let cleanHub = try #require(await registry.hub(surfaceId: "surface"))
        await cleanHub.tick()
        await registry.unsubscribe(clean)
        #expect(await source.releaseCount(surfaceId: "surface") == iterationCount + 1)
        print("cancellationStress.iterations=\(iterationCount) releases=\(iterationCount + 1) activeHubs=0")
    }

    @Test func repeatedFinalReleaseReacquireRacesPreserveGenerationAndCapacity() async throws {
        let iterationCount = 64
        let source = ScriptedTerminalSourceReader(steps: (0..<iterationCount).map {
            .immediate(Self.legacyUpdate(text: "generation-\($0)"))
        })
        await source.setSuspendsReleases(true)
        let releaseProbe = await BoundedAsyncStreamProbe.make(stream: source.releaseEvents())
        let registry = SurfaceRenderHubRegistry(
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5),
            maximumSurfaces: 1,
            clockFactory: { ManualSurfaceRenderClock() }
        )
        var subscription = try await registry.subscribe(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            onDiff: { _, _ in },
            onChecksum: { _, _ in }
        )

        for iteration in 0..<iterationCount {
            let oldHub = try #require(await registry.hub(surfaceId: "surface"))
            let releasingSubscription = subscription
            let oldGeneration = releasingSubscription.generation
            await oldHub.tick()

            let release = Task { await registry.unsubscribe(releasingSubscription) }
            #expect(try await releaseProbe.next() == iteration + 1)
            #expect(await registry.hub(surfaceId: "surface") == nil)
            #expect(await registry.cleanupTaskCount == 1)

            let acquire = Task {
                try await registry.subscribe(
                    workspaceId: "workspace",
                    surfaceId: "surface",
                    lines: 120,
                    onDiff: { _, _ in },
                    onChecksum: { _, _ in }
                )
            }
            await #expect(throws: SurfaceRenderHubError.surfaceLimitReached(1)) {
                _ = try await registry.subscribe(
                    workspaceId: "workspace",
                    surfaceId: "other-\(iteration)",
                    lines: 120,
                    onDiff: { _, _ in },
                    onChecksum: { _, _ in }
                )
            }

            await source.completeNextRelease()
            await release.value
            subscription = try await acquire.value
            let newHub = try #require(await registry.hub(surfaceId: "surface"))
            #expect(ObjectIdentifier(oldHub) != ObjectIdentifier(newHub))
            #expect(subscription.generation != oldGeneration)
            #expect(await newHub.isStopped == false)
            #expect(await newHub.subscriberCount == 1)
        }

        await source.setSuspendsReleases(false)
        await registry.unsubscribe(subscription)
        #expect(await source.releaseCount(surfaceId: "surface") == iterationCount + 1)
        print("generationStress.iterations=\(iterationCount) releases=\(iterationCount + 1) capacity=1")
        #expect(await registry.activeHubCount == 0)
        #expect(await registry.cleanupTaskCount == 0)
    }

    @Test func stableLegacyScreenEmitsOnlyPeriodicChecksum() async throws {
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.legacyUpdate(text: "stable")),
            .immediate(Self.legacyUpdate(text: "stable")),
            .immediate(Self.legacyUpdate(text: "stable")),
        ])
        let clock = ManualSurfaceRenderClock()
        let checksum = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let checksumProbe = await BoundedAsyncStreamProbe.make(stream: checksum.stream)
        let hub = SurfaceRenderHub(
            workspaceId: "workspace",
            surfaceId: "legacy",
            lines: 120,
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5),
            clock: clock
        )
        _ = try await hub.subscribe(
            onDiff: { _, _ in },
            onChecksum: { _, revision in checksum.continuation.yield(revision) }
        )

        await hub.tick()
        #expect(await hub.metrics.fanoutDeliveries == 1)
        await clock.advanceTimeOnly(by: 4)
        await hub.tick()
        #expect(await hub.metrics.fanoutDeliveries == 1)
        await clock.advanceTimeOnly(by: 2)
        await hub.tick()

        #expect(await hub.metrics.fanoutDeliveries == 2)
        if await hub.metrics.fanoutDeliveries == 2 {
            #expect(try await checksumProbe.next() == 1)
        }
        #expect(await source.readCount(surfaceId: "legacy") == 3)
        print("legacyChecksum.beforeIntervalFanout=1 periodicFanout=2 checksumRevision=1")
        await hub.stop()
    }

    @Test func schedulerBackoffUsesCompletedOutcomeAndResetsAfterRecovery() async throws {
        let source = ScriptedTerminalSourceReader(steps: [
            .failure("first"),
            .failure("second"),
            .immediate(Self.legacyUpdate(text: "recovered")),
        ])
        let clock = ManualSurfaceRenderClock()
        let sleepProbe = await BoundedAsyncStreamProbe.make(stream: clock.requests())
        let readProbe = await BoundedAsyncStreamProbe.make(stream: source.readEvents())
        let diff = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let diffProbe = await BoundedAsyncStreamProbe.make(stream: diff.stream)
        let hub = SurfaceRenderHub(
            workspaceId: "workspace",
            surfaceId: "backoff",
            lines: 120,
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5, maximumErrorBackoff: 2),
            clock: clock
        )
        _ = try await hub.subscribe(
            onDiff: { revision, _ in diff.continuation.yield(revision) },
            onChecksum: { _, _ in }
        )

        let initialDelay = try await sleepProbe.next()
        await clock.advance(by: initialDelay.seconds)
        #expect(try await readProbe.next().readCount == 1)
        let firstRetryDelay = try await sleepProbe.next()

        await clock.advance(by: firstRetryDelay.seconds)
        #expect(try await readProbe.next().readCount == 2)
        let secondRetryDelay = try await sleepProbe.next()

        await clock.advance(by: secondRetryDelay.seconds)
        #expect(try await readProbe.next().readCount == 3)
        #expect(try await diffProbe.next() == 1)
        let recoveredDelay = try await sleepProbe.next()

        #expect(Self.approximatelyEqual(initialDelay.seconds, 1.0 / 15.0))
        #expect(Self.approximatelyEqual(firstRetryDelay.seconds, 2.0 / 15.0))
        #expect(Self.approximatelyEqual(secondRetryDelay.seconds, 4.0 / 15.0))
        #expect(Self.approximatelyEqual(recoveredDelay.seconds, 1.0 / 15.0))
        #expect(await hub.metrics.errors == 2)
        #expect(await hub.metrics.updatedOutcomes == 1)
        #expect(await source.maximumInFlightReadCount() == 1)
        print("schedulerDelays.initial=\(initialDelay.seconds) firstRetry=\(firstRetryDelay.seconds) secondRetry=\(secondRetryDelay.seconds) recovery=\(recoveredDelay.seconds)")
        await hub.stop()
    }

    @Test func sourceErrorsBackOffOnInjectedClockWithoutSpinning() async throws {
        let source = ScriptedTerminalSourceReader(steps: [
            .failure("offline"),
        ])
        let clock = ManualSurfaceRenderClock()
        let sleepProbe = await BoundedAsyncStreamProbe.make(stream: clock.requests())
        let readProbe = await BoundedAsyncStreamProbe.make(stream: source.readEvents())
        let hub = SurfaceRenderHub(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            reader: source,
            configuration: .init(
                activeFps: 15,
                idleFps: 5,
                maximumErrorBackoff: 2
            ),
            clock: clock
        )
        _ = try await hub.subscribe(onDiff: { _, _ in }, onChecksum: { _, _ in })

        let firstDelay = try await sleepProbe.next()
        await clock.advance(by: firstDelay.seconds)
        _ = try await readProbe.next()
        let retryDelay = try await sleepProbe.next()

        #expect(Self.approximatelyEqual(firstDelay.seconds, 1.0 / 15.0))
        #expect(Self.approximatelyEqual(retryDelay.seconds, 2.0 / 15.0))
        #expect(await source.readCount(surfaceId: "surface") == 1)
        #expect(await source.inFlightReadCount() == 0)
        #expect(await hub.metrics.errors == 1)
        #expect(await hub.lastErrorDescription == "failure(\"offline\")")
        await hub.stop()
    }

    @Test func fakeClockProvesActiveToIdleAndInputWake() async throws {
        let identity = CMUXTerminalReplayIdentity(epoch: Self.epochA, revision: 1)
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.renderUpdate(identity: identity, text: "active")),
            .immediate(.unchanged(identity)),
        ])
        let clock = ManualSurfaceRenderClock()
        let sleepProbe = await BoundedAsyncStreamProbe.make(stream: clock.requests())
        let readProbe = await BoundedAsyncStreamProbe.make(stream: source.readEvents())
        let diff = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let diffProbe = await BoundedAsyncStreamProbe.make(stream: diff.stream)
        let hub = SurfaceRenderHub(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5, idleAfter: 1.5),
            clock: clock
        )
        _ = try await hub.subscribe(
            onDiff: { revision, _ in diff.continuation.yield(revision) },
            onChecksum: { _, _ in }
        )

        let firstActiveDelay = try await sleepProbe.next()
        await clock.advance(by: firstActiveDelay.seconds)
        _ = try await readProbe.next()
        _ = try await diffProbe.next()
        let secondActiveDelay = try await sleepProbe.next()
        #expect(Self.approximatelyEqual(secondActiveDelay.seconds, 1.0 / 15.0))

        await clock.advance(by: 1.6)
        _ = try await readProbe.next()
        let idleDelay = try await sleepProbe.next()
        #expect(Self.approximatelyEqual(idleDelay.seconds, 1.0 / 5.0))
        #expect(await hub.cadence == .idle)
        #expect(await hub.currentFps == 5)

        await hub.noteUserInput()
        let wokenDelay = try await sleepProbe.next()
        #expect(Self.approximatelyEqual(wokenDelay.seconds, 1.0 / 15.0))
        #expect(await hub.cadence == .active)
        #expect(await hub.currentFps == 15)
        await hub.stop()
    }

    @Test func unchangedLegacySnapshotsCanReturnToIdleCadence() async throws {
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.legacyUpdate(text: "same")),
            .immediate(Self.legacyUpdate(text: "same")),
        ])
        let clock = ManualSurfaceRenderClock()
        let sleepProbe = await BoundedAsyncStreamProbe.make(stream: clock.requests())
        let readProbe = await BoundedAsyncStreamProbe.make(stream: source.readEvents())
        let diff = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let diffProbe = await BoundedAsyncStreamProbe.make(stream: diff.stream)
        let hub = SurfaceRenderHub(
            workspaceId: "workspace",
            surfaceId: "legacy",
            lines: 120,
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5, idleAfter: 1.5),
            clock: clock
        )
        _ = try await hub.subscribe(
            onDiff: { revision, _ in diff.continuation.yield(revision) },
            onChecksum: { _, _ in }
        )

        let firstDelay = try await sleepProbe.next()
        await clock.advance(by: firstDelay.seconds)
        _ = try await readProbe.next()
        _ = try await diffProbe.next()
        _ = try await sleepProbe.next()
        await clock.advance(by: 1.6)
        _ = try await readProbe.next()
        let idleDelay = try await sleepProbe.next()

        #expect(Self.approximatelyEqual(idleDelay.seconds, 1.0 / 5.0))
        #expect(await hub.cadence == .idle)
        #expect(await hub.metrics.updatedOutcomes == 2)
        #expect(await hub.metrics.fanoutDeliveries == 1)
        await hub.stop()
    }

    @Test func lastUnsubscribeCancelsReadReleasesAndRemovesRegistryState() async throws {
        let source = ScriptedTerminalSourceReader(steps: [
            .suspended(Self.renderUpdate(epoch: Self.epochA, revision: 1, text: "late")),
        ])
        let clock = ManualSurfaceRenderClock()
        let sleepProbe = await BoundedAsyncStreamProbe.make(stream: clock.requests())
        let readProbe = await BoundedAsyncStreamProbe.make(stream: source.readEvents())
        let cancellationProbe = await BoundedAsyncStreamProbe.make(stream: source.cancellationEvents())
        let manager = SessionManager(
            terminalReader: source,
            defaultFps: 15,
            idleFps: 5,
            clockFactory: { clock }
        )
        let session = await manager.attach(deviceId: "device") { _ in }
        try await session.subscribe(workspaceId: "workspace", surfaceId: "surface", lines: 120)
        let hub = try #require(await manager.renderHub(surfaceId: "surface"))

        let delay = try await sleepProbe.next()
        await clock.advance(by: delay.seconds)
        _ = try await readProbe.next()
        let unsubscribe = Task { await session.unsubscribe(surfaceId: "surface") }
        #expect(try await cancellationProbe.next() == 1)
        await unsubscribe.value

        #expect(await hub.isStopped)
        #expect(await hub.subscriberCount == 0)
        #expect(await hub.hasReadInFlight == false)
        #expect(await hub.metrics.fanoutDeliveries == 0)
        #expect(await source.releaseCount(surfaceId: "surface") == 1)
        #expect(await manager.activeRenderHubCount == 0)
        #expect(await session.activeSurfaceCount == 0)
        await manager.detach(session: session)
    }

    @Test func reconnectStartsASeparateCleanHubAfterRelease() async throws {
        let firstIdentity = CMUXTerminalReplayIdentity(epoch: Self.epochA, revision: 7)
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.renderUpdate(identity: firstIdentity, text: "first")),
            .immediate(Self.renderUpdate(identity: firstIdentity, text: "reconnected")),
        ])
        let registry = SurfaceRenderHubRegistry(
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5),
            clockFactory: { ManualSurfaceRenderClock() }
        )

        let firstSubscription = try await registry.subscribe(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            onDiff: { _, _ in },
            onChecksum: { _, _ in }
        )
        let firstHub = try #require(await registry.hub(surfaceId: "surface"))
        await firstHub.tick()
        await registry.unsubscribe(firstSubscription)
        #expect(await source.releaseCount(surfaceId: "surface") == 1)

        let secondSubscription = try await registry.subscribe(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            onDiff: { _, _ in },
            onChecksum: { _, _ in }
        )
        let secondHub = try #require(await registry.hub(surfaceId: "surface"))
        await secondHub.tick()

        #expect(ObjectIdentifier(firstHub) != ObjectIdentifier(secondHub))
        #expect(await secondHub.currentScreen?.rows == ["reconnected"])
        #expect(await secondHub.metrics.updatedOutcomes == 1)
        #expect(await source.readCount(surfaceId: "surface") == 2)
        await registry.unsubscribe(secondSubscription)
        #expect(await source.releaseCount(surfaceId: "surface") == 2)
        #expect(await registry.activeHubCount == 0)
        #expect(await registry.cleanupTaskCount == 0)
    }

    @Test func unsubscribedConsumerReceivesNoLaterDelivery() async throws {
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.legacyUpdate(text: "only-second")),
        ])
        let firstDiff = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let secondDiff = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let secondProbe = await BoundedAsyncStreamProbe.make(stream: secondDiff.stream)
        let hub = SurfaceRenderHub(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5),
            clock: ManualSurfaceRenderClock()
        )
        let first = try await hub.subscribe(
            onDiff: { revision, _ in firstDiff.continuation.yield(revision) },
            onChecksum: { _, _ in }
        )
        _ = try await hub.subscribe(
            onDiff: { revision, _ in secondDiff.continuation.yield(revision) },
            onChecksum: { _, _ in }
        )

        #expect(await hub.unsubscribe(first) == false)
        await hub.tick()

        #expect(try await secondProbe.next() == 1)
        #expect(await hub.metrics.fanoutDeliveries == 1)
        #expect(await hub.subscriberCount == 1)
        await hub.stop()
    }

    @Test func staleEpochAndMalformedOutcomesCannotCorruptAuthoritativeState() async throws {
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.renderUpdate(epoch: Self.epochA, revision: 2, text: "a2")),
            .immediate(Self.renderUpdate(epoch: Self.epochA, revision: 1, text: "stale")),
            .immediate(Self.renderUpdate(epoch: Self.epochB, revision: 1, text: "b1")),
            .immediate(Self.renderUpdate(epoch: Self.epochA, revision: 3, text: "retired")),
            .immediate(.updated(CMUXTerminalReadUpdate(
                screen: Self.screen("malformed"),
                sourceMode: .renderGrid,
                replayIdentity: nil
            ))),
            .immediate(.ignored(.staleRevision(received: 0, current: 1))),
        ])
        let hub = SurfaceRenderHub(
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5),
            clock: ManualSurfaceRenderClock()
        )
        _ = try await hub.subscribe(onDiff: { _, _ in }, onChecksum: { _, _ in })

        for _ in 0..<6 {
            await hub.tick()
        }

        #expect(await hub.currentScreen?.rows == ["b1"])
        #expect(await hub.replayIdentity == .init(epoch: Self.epochB, revision: 1))
        #expect(await hub.metrics.updatedOutcomes == 2)
        #expect(await hub.metrics.ignoredOutcomes == 4)
        #expect(await hub.metrics.errors == 1)
        #expect(await hub.metrics.fanoutDeliveries == 2)
        await hub.stop()
    }

    @Test func registryAndSubscriberCollectionsAreBounded() async throws {
        let source = ScriptedTerminalSourceReader(steps: [])
        let registry = SurfaceRenderHubRegistry(
            reader: source,
            configuration: .init(
                activeFps: 15,
                idleFps: 5,
                maximumSubscribers: 1
            ),
            maximumSurfaces: 1,
            clockFactory: { ManualSurfaceRenderClock() }
        )
        let first = try await registry.subscribe(
            workspaceId: "workspace",
            surfaceId: "first",
            lines: 120,
            onDiff: { _, _ in },
            onChecksum: { _, _ in }
        )

        await #expect(throws: SurfaceRenderHubError.subscriberLimitReached(
            surfaceId: "first",
            limit: 1
        )) {
            _ = try await registry.subscribe(
                workspaceId: "workspace",
                surfaceId: "first",
                lines: 120,
                onDiff: { _, _ in },
                onChecksum: { _, _ in }
            )
        }
        await #expect(throws: SurfaceRenderHubError.surfaceLimitReached(1)) {
            _ = try await registry.subscribe(
                workspaceId: "workspace",
                surfaceId: "second",
                lines: 120,
                onDiff: { _, _ in },
                onChecksum: { _, _ in }
            )
        }
        await registry.unsubscribe(first)
    }

    @Test func manualDriverPrintsSharedFanoutAndLifecycleCounters() async throws {
        let identity = CMUXTerminalReplayIdentity(epoch: Self.epochA, revision: 1)
        let source = ScriptedTerminalSourceReader(steps: [
            .immediate(Self.renderUpdate(identity: identity, text: "driver")),
            .immediate(.unchanged(identity)),
        ])
        let hub = SurfaceRenderHub(
            workspaceId: "workspace",
            surfaceId: "manual",
            lines: 120,
            reader: source,
            configuration: .init(activeFps: 15, idleFps: 5),
            clock: ManualSurfaceRenderClock()
        )
        let first = try await hub.subscribe(onDiff: { _, _ in }, onChecksum: { _, _ in })
        let second = try await hub.subscribe(onDiff: { _, _ in }, onChecksum: { _, _ in })

        await hub.tick()
        let readsAfterUpdatedTick = await source.readCount(surfaceId: "manual")
        await hub.tick()
        let metrics = await hub.metrics
        _ = await hub.unsubscribe(first)
        _ = await hub.unsubscribe(second)
        await hub.stop()
        let releaseCount = await source.releaseCount(surfaceId: "manual")

        print("manual.updatedTickReads=\(readsAfterUpdatedTick)")
        print("manual.twoSubscriberFanout=\(metrics.fanoutDeliveries)")
        print("manual.maxInFlight=\(metrics.maximumInFlightReads)")
        print("manual.unchangedSkip=\(metrics.unchangedOutcomes)")
        print("manual.totalReads=\(metrics.readAttempts)")
        print("manual.releaseCount=\(releaseCount)")

        #expect(readsAfterUpdatedTick == 1)
        #expect(metrics.fanoutDeliveries == 2)
        #expect(metrics.maximumInFlightReads == 1)
        #expect(metrics.unchangedOutcomes == 1)
        #expect(releaseCount == 1)
    }

    private static let epochA = "00000000-0000-4000-8000-000000000001"
    private static let epochB = "00000000-0000-4000-8000-000000000002"

    private static func legacyUpdate(text: String) -> CMUXTerminalReadOutcome {
        .updated(CMUXTerminalReadUpdate(
            screen: screen(text),
            sourceMode: .legacyText,
            replayIdentity: nil
        ))
    }

    private static func renderUpdate(
        epoch: String,
        revision: UInt64,
        text: String
    ) -> CMUXTerminalReadOutcome {
        renderUpdate(
            identity: CMUXTerminalReplayIdentity(epoch: epoch, revision: revision),
            text: text
        )
    }

    private static func renderUpdate(
        identity: CMUXTerminalReplayIdentity,
        text: String
    ) -> CMUXTerminalReadOutcome {
        .updated(CMUXTerminalReadUpdate(
            screen: screen(text, identity: identity),
            sourceMode: .renderGrid,
            replayIdentity: identity
        ))
    }

    private static func screen(
        _ text: String,
        identity: CMUXTerminalReplayIdentity? = nil
    ) -> Screen {
        Screen(
            rev: 0,
            rows: [text],
            cols: text.count,
            cursor: .hidden,
            snapshotMetadata: identity.map {
                ScreenSnapshotMetadata(
                    renderEpoch: $0.epoch,
                    renderRevision: $0.revision,
                    viewportRows: 1,
                    terminalForeground: "#eaeaea",
                    terminalBackground: "#101820",
                    terminalThemeRevision: nil
                )
            }
        )
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.000_001
    }
}
