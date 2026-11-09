import Foundation
import SharedKit

/// Forwards cmux events to phones and APNs one at a time, in the order cmux sent them.
///
/// A `notification.created` waits for its content (bounded by the enricher's timeout) and
/// every later event waits behind it, so phones never see a `notification.read` before the
/// card it marks. The `notification.requested` socket audit goes nowhere.
final class NotificationEventPipeline: Sendable {
    enum Route: Equatable, Sendable {
        case drop
        case broadcast
        case broadcastAndPush
    }

    private let continuation: AsyncStream<EventFrame>.Continuation
    private let consumer: Task<Void, Never>

    init(
        enrich: @escaping @Sendable (EventFrame) async -> EventFrame,
        broadcast: @escaping @Sendable (PushFrame) async -> Void,
        push: @escaping @Sendable (EventFrame) async -> Void
    ) {
        var continuation: AsyncStream<EventFrame>.Continuation!
        let stream = AsyncStream<EventFrame> { continuation = $0 }
        self.continuation = continuation
        consumer = Task {
            for await event in stream {
                guard Self.route(event) != .drop else { continue }
                let forwarded = await enrich(event)
                await broadcast(.event(forwarded))
                if Self.route(forwarded) == .broadcastAndPush {
                    Task { await push(forwarded) }
                }
            }
        }
    }

    func submit(_ event: EventFrame) {
        continuation.yield(event)
    }

    func finish() async {
        continuation.finish()
        await consumer.value
    }

    static func route(_ event: EventFrame) -> Route {
        if event.name == InboxNotification.requestedEventName { return .drop }
        return InboxNotification.isInboxEvent(event) ? .broadcastAndPush : .broadcast
    }
}
