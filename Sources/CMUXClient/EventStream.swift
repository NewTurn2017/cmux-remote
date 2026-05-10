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
        // Fire-and-forget: cmux replies once with ok and then keeps pushing events.
        _ = try? await client.call(method: "events.stream", params: .object(["categories": cats]))
    }
}
