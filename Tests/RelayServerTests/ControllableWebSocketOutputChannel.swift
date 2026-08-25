import NIOCore
import NIOEmbedded
@testable import RelayServer

/// Deterministic event-loop channel whose writability and write futures are test-controlled.
final class ControllableWebSocketOutputChannel: WebSocketOutputChannel {
    let embeddedEventLoop = EmbeddedEventLoop()
    var isActive = true
    var isWritable = true
    var automaticallyCompletesWrites = false
    private(set) var writtenTexts: [String] = []
    private(set) var closeCount = 0
    private(set) var inFlightWrites = 0
    private(set) var maximumInFlightWrites = 0

    private var pendingPromises: [EventLoopPromise<Void>] = []

    var eventLoop: any EventLoop { embeddedEventLoop }
    var pendingWriteCount: Int { pendingPromises.count }

    func writeText(_ text: String) -> EventLoopFuture<Void> {
        writtenTexts.append(text)
        inFlightWrites += 1
        maximumInFlightWrites = max(maximumInFlightWrites, inFlightWrites)
        let promise = embeddedEventLoop.makePromise(of: Void.self)
        if automaticallyCompletesWrites {
            inFlightWrites -= 1
            promise.succeed(())
        } else {
            pendingPromises.append(promise)
        }
        return promise.futureResult
    }

    func close() {
        closeCount += 1
        isActive = false
    }

    func completeNextWrite() {
        guard !pendingPromises.isEmpty else { return }
        let promise = pendingPromises.removeFirst()
        inFlightWrites -= 1
        promise.succeed(())
        embeddedEventLoop.run()
    }

    func failNextWrite(_ error: any Error = ControllableWebSocketOutputError.failed) {
        guard !pendingPromises.isEmpty else { return }
        let promise = pendingPromises.removeFirst()
        inFlightWrites -= 1
        promise.fail(error)
        embeddedEventLoop.run()
    }

    func run() {
        embeddedEventLoop.run()
    }
}
