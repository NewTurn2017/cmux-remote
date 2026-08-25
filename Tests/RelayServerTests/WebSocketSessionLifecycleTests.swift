import NIOCore
import NIOPosix
import Testing
@testable import RelayCore
@testable import RelayServer

@Suite("WebSocketSessionLifecycleTests", .serialized)
struct WebSocketSessionLifecycleTests {
    @Test func suspendedAttachCompletedAfterInactiveIsDetachedNotInstalled() async throws {
        try await withFixture(modes: [.suspended]) { fixture in
            let generation = try await fixture.eventLoop.submit {
                fixture.lifecycle.activate()
            }.get()
            let attach = Task {
                try await fixture.lifecycle.attach(
                    deviceId: "device",
                    generation: generation,
                    sendOutputEvent: { _ in }
                )
            }
            #expect(try await fixture.attachProbe.next() == 1)
            _ = try await fixture.eventLoop.submit {
                fixture.lifecycle.invalidate()
            }.get()

            await fixture.manager.resumeAttach(attempt: 1)
            #expect(try await attach.value == false)
            #expect(await fixture.manager.detachCount() == 1)
            #expect(await fixture.backing.activeSessionCount == 0)
        }
    }

    @Test func reconnectGenerationRejectsOldAttachAndKeepsNewSession() async throws {
        try await withFixture(modes: [.suspended, .immediate]) { fixture in
            let firstGeneration = try await fixture.eventLoop.submit {
                fixture.lifecycle.activate()
            }.get()
            let firstAttach = Task {
                try await fixture.lifecycle.attach(
                    deviceId: "device",
                    generation: firstGeneration,
                    sendOutputEvent: { _ in }
                )
            }
            #expect(try await fixture.attachProbe.next() == 1)
            _ = try await fixture.eventLoop.submit {
                fixture.lifecycle.invalidate()
            }.get()

            let secondGeneration = try await fixture.eventLoop.submit {
                fixture.lifecycle.activate()
            }.get()
            let secondInstalled = try await fixture.lifecycle.attach(
                deviceId: "device",
                generation: secondGeneration,
                sendOutputEvent: { _ in }
            )
            #expect(try await fixture.attachProbe.next() == 2)
            #expect(secondInstalled)

            await fixture.manager.resumeAttach(attempt: 1)
            #expect(try await firstAttach.value == false)
            #expect(await fixture.manager.detachCount() == 1)
            #expect(await fixture.backing.activeSessionCount == 1)

            let current = try await fixture.eventLoop.submit {
                fixture.lifecycle.invalidate()
            }.get()
            let installedSession = try #require(current)
            await fixture.manager.detach(session: installedSession)
            #expect(await fixture.manager.detachCount() == 2)
            #expect(await fixture.backing.activeSessionCount == 0)
        }
    }

    @Test func repeatedInactiveAndRemovedDetachInstalledSessionExactlyOnce() async throws {
        try await withFixture(modes: [.immediate]) { fixture in
            let generation = try await fixture.eventLoop.submit {
                fixture.lifecycle.activate()
            }.get()
            #expect(try await fixture.lifecycle.attach(
                deviceId: "device",
                generation: generation,
                sendOutputEvent: { _ in }
            ))
            #expect(try await fixture.attachProbe.next() == 1)

            let first = try await fixture.eventLoop.submit {
                fixture.lifecycle.invalidate()
            }.get()
            let second = try await fixture.eventLoop.submit {
                fixture.lifecycle.invalidate()
            }.get()
            let installedSession = try #require(first)
            #expect(second == nil)
            await fixture.manager.detach(session: installedSession)

            #expect(await fixture.manager.detachCount() == 1)
            #expect(await fixture.backing.activeSessionCount == 0)
        }
    }

    @Test func attachFailureNeverInstallsOrIndexesSession() async throws {
        try await withFixture(modes: [.failure]) { fixture in
            let generation = try await fixture.eventLoop.submit {
                fixture.lifecycle.activate()
            }.get()

            await #expect(throws: ControllableWebSocketSessionError.failed) {
                _ = try await fixture.lifecycle.attach(
                    deviceId: "device",
                    generation: generation,
                    sendOutputEvent: { _ in }
                )
            }
            #expect(try await fixture.attachProbe.next() == 1)
            let installed = try await fixture.eventLoop.submit {
                fixture.lifecycle.currentSession(generation: generation)
            }.get()
            #expect(installed == nil)
            #expect(await fixture.manager.detachCount() == 0)
            #expect(await fixture.backing.activeSessionCount == 0)
        }
    }

    private func withFixture(
        modes: [ControllableWebSocketSessionMode],
        body: (WebSocketSessionLifecycleFixture) async throws -> Void
    ) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let backing = SessionManager(
            reader: FixtureSurfaceReader(),
            defaultFps: 15,
            idleFps: 5
        )
        let manager = ControllableWebSocketSessionManager(
            backing: backing,
            modes: modes
        )
        let eventLoop = group.next()
        let lifecycle = WebSocketSessionLifecycle(
            eventLoop: eventLoop,
            manager: manager
        )
        let attachEvents = await manager.attachEvents()
        let attachProbe = await RelayServerBoundedStreamProbe.make(stream: attachEvents)
        let fixture = WebSocketSessionLifecycleFixture(
            backing: backing,
            manager: manager,
            eventLoop: eventLoop,
            lifecycle: lifecycle,
            attachProbe: attachProbe
        )
        do {
            try await body(fixture)
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }
}
