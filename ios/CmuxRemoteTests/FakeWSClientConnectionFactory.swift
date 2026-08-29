import Foundation
@testable import CmuxRemote

actor FakeWSClientConnectionFactory: WSClientConnectionFactory {
    private let creationStream: AsyncStream<Int>
    private let creationContinuation: AsyncStream<Int>.Continuation
    private let receiveProbe = WSClientReceiveProbe()
    private var connections: [FakeWSClientConnection] = []
    private var capturedHeaders: [[String: String]] = []
    private var capturedProtocols: [[String]] = []

    init() {
        (creationStream, creationContinuation) = AsyncStream.makeStream(of: Int.self)
    }

    func makeConnection(
        url: URL,
        headers: [String: String],
        protocols: [String],
        onOpen: @escaping @Sendable () async -> Void,
        onClose: @escaping @Sendable (Int) async -> Void
    ) -> any WSClientConnection {
        let connection = FakeWSClientConnection(
            onOpen: onOpen,
            onClose: onClose,
            receiveProbe: receiveProbe
        )
        connections.append(connection)
        capturedHeaders.append(headers)
        capturedProtocols.append(protocols)
        creationContinuation.yield(connections.count - 1)
        return connection
    }

    func creations() -> AsyncStream<Int> {
        creationStream
    }

    func receiveActivities() async -> AsyncStream<Int> {
        await receiveProbe.activities()
    }

    func maximumActiveReceiveCount() async -> Int {
        await receiveProbe.observedMaximumActiveCount()
    }

    func connection(at index: Int) -> FakeWSClientConnection {
        connections[index]
    }

    func connectionCount() -> Int {
        connections.count
    }

    func headers(at index: Int) -> [String: String] {
        capturedHeaders[index]
    }

    func protocols(at index: Int) -> [String] {
        capturedProtocols[index]
    }
}
