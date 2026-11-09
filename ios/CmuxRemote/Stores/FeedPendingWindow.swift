import Foundation
import SharedKit

enum FeedPendingWindow {
    /// How long a pending request stays answerable. cmux's hook waits 125 s; the measured
    /// drop from `feed.list {pending_only: true}` came at 115 s.
    static let expectedSeconds = 115
    /// A request that leaves the list at least this old is treated as expired, not answered.
    static let expiredDepartureAgeSeconds = expectedSeconds - 5
    static let departedDisplaySeconds: Double = 10
    static let urgentSeconds = 30

    static func remainingSeconds(createdAt: Int64?, now: Date) -> Int? {
        guard let createdAt else { return nil }
        let age = Int(floor(ageSeconds(createdAt: createdAt, now: now)))
        return min(expectedSeconds, max(0, expectedSeconds - age))
    }

    static func ageSeconds(createdAt: Int64, now: Date) -> Double {
        now.timeIntervalSince1970 - Double(createdAt) / 1_000
    }

    static func isExpired(_ item: FeedPendingItem, now: Date) -> Bool {
        remainingSeconds(createdAt: item.createdAt, now: now) == 0
    }

    static func isUrgent(remainingSeconds seconds: Int) -> Bool {
        seconds > 0 && seconds <= urgentSeconds
    }

    static func remainingText(seconds: Int) -> String {
        let minutes = seconds / 60
        let rest = seconds % 60
        if minutes > 0, rest > 0 {
            return String(
                format: String(localized: "feed.remaining.minutes_seconds", defaultValue: "About %1$d min %2$d s left"),
                minutes,
                rest
            )
        }
        if minutes > 0 {
            return String(format: String(localized: "feed.remaining.minutes", defaultValue: "About %d min left"), minutes)
        }
        return String(format: String(localized: "feed.remaining.seconds", defaultValue: "About %d s left"), rest)
    }
}

/// A request that left the pending list without an answer from this phone. It stays on
/// screen, dimmed, for ``FeedPendingWindow/departedDisplaySeconds`` so it doesn't just vanish.
struct FeedDepartedItem: Equatable {
    enum Reason: String, Equatable {
        case expired
        case handledElsewhere
    }

    let item: FeedPendingItem
    let reason: Reason
    let departedAt: Date

    static func reason(for item: FeedPendingItem, now: Date) -> Reason {
        guard let createdAt = item.createdAt else { return .handledElsewhere }
        let age = FeedPendingWindow.ageSeconds(createdAt: createdAt, now: now)
        return age >= Double(FeedPendingWindow.expiredDepartureAgeSeconds) ? .expired : .handledElsewhere
    }

    func isVisible(at now: Date) -> Bool {
        now.timeIntervalSince(departedAt) < FeedPendingWindow.departedDisplaySeconds
    }

    var message: String {
        switch reason {
        case .expired:
            return String(localized: "feed.departed.expired", defaultValue: "Expired · Answer in the Mac terminal")
        case .handledElsewhere:
            return String(localized: "feed.departed.handled_elsewhere", defaultValue: "Handled on the Mac or elsewhere")
        }
    }
}

enum FeedEntry: Identifiable {
    case live(FeedPendingItem)
    case departed(FeedDepartedItem)

    var id: String {
        switch self {
        case .live(let item): return item.requestId
        case .departed(let departed): return departed.item.requestId
        }
    }

    var createdAt: Int64? {
        switch self {
        case .live(let item): return item.createdAt
        case .departed(let departed): return departed.item.createdAt
        }
    }
}
