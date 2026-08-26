import NIOCore
import NIOPosix
import Testing
@testable import RelayServer

@Suite("WSActionQueueTests", .serialized)
struct WSActionQueueTests {
    @Test func slowRPCFloodStopsAtOutstandingActionBoundAndResumesInOrder() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let facade = SuspendingInboundCMUXFacade()
        let machine = WSProtocolMachine(cmux: facade)
        _ = await machine.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)
        let startedProbe = await RelayServerBoundedStreamProbe.make(
            stream: facade.startedMethods()
        )
        let capacityAvailable = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let capacityProbe = await RelayServerBoundedStreamProbe.make(
            stream: capacityAvailable.stream
        )
        let queue = WSActionQueue(
            eventLoop: eventLoop,
            maximumOutstandingActions: 3,
            onCapacityAvailable: { capacityAvailable.continuation.yield() }
        )

        let admitted = try await eventLoop.submit {
            ["1", "2", "3", "4"].map { id in
                queue.enqueue {
                    _ = await machine.processText(
                        #"{"id":"\#(id)","method":"slow.\#(id)","params":{}}"#
                    )
                }
            }
        }.get()

        #expect(try await startedProbe.next() == "slow.1")
        let outstanding = try await eventLoop.submit {
            queue.outstandingActionCount
        }.get()
        #expect(admitted == [true, true, true, false])
        #expect(outstanding == 3)

        facade.release()
        _ = try await capacityProbe.next()
        #expect(try await startedProbe.next() == "slow.2")
        #expect(try await startedProbe.next() == "slow.3")
        try await eventLoop.submit { queue.invalidate() }.get()
        try await group.shutdownGracefully()
    }

    @Test func invalidationCancelsActiveActionAndSuppressesQueuedAndPostDisconnectWork() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let blocker = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let cancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let startedProbe = await RelayServerBoundedStreamProbe.make(stream: started.stream)
        let cancelledProbe = await RelayServerBoundedStreamProbe.make(stream: cancelled.stream)
        let recorder = InboundActionExecutionRecorder()
        let queue = WSActionQueue(
            eventLoop: eventLoop,
            maximumOutstandingActions: 3,
            onCapacityAvailable: {}
        )

        let admitted = try await eventLoop.submit {
            [
                queue.enqueue {
                    started.continuation.yield()
                    for await _ in blocker.stream {}
                    if Task.isCancelled {
                        cancelled.continuation.yield()
                    }
                },
                queue.enqueue {
                    await recorder.record("queued")
                },
            ]
        }.get()
        #expect(admitted == [true, true])
        _ = try await startedProbe.next()

        let postDisconnectAdmitted = try await eventLoop.submit {
            queue.invalidate()
            return queue.enqueue {
                await recorder.record("post-disconnect")
            }
        }.get()

        _ = try await cancelledProbe.next()
        let outstanding = try await eventLoop.submit {
            queue.outstandingActionCount
        }.get()
        #expect(postDisconnectAdmitted == false)
        #expect(outstanding == 0)
        #expect(await recorder.snapshot() == [])
        blocker.continuation.finish()
        try await group.shutdownGracefully()
    }
}
