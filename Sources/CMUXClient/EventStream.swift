import Foundation
import SharedKit

public actor EventStream {
    private let client: CMUXClient
    private let sink: @Sendable (EventFrame) -> Void
    private var started = false

    public init(client: CMUXClient, sink: @escaping @Sendable (EventFrame) -> Void) {
        self.client = client
        self.sink = sink
    }

    public func start(categories: [EventCategory]) async {
        guard !started else { return }
        started = true
        let sink = self.sink
        await client.onEventStream { frame in
            if case .event(let ev) = frame {
                sink(ev)
            }
        }
        let cats: JSONValue = .array(categories.map { .string($0.rawValue) })
        // Fire-and-forget: cmux 0.64.12 acks the subscribe with a `cmux-events`
        // subscription envelope (no matching RPC id) and then streams events.
        // Using `call` here would block until the request timeout on every
        // attach; `send` writes the subscribe and returns immediately.
        try? await client.send(method: "events.stream", params: .object(["categories": cats]))
    }
}
