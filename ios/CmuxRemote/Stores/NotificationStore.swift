import Observation
import SharedKit

@MainActor
@Observable
public final class NotificationStore {
    public var items: [NotificationRecord] = []
    public var onNew: (@MainActor (NotificationRecord) -> Void)?
    public var localNotificationsEnabled = true

    public private(set) var unreadByWorkspace: [String: Int] = [:]
    public private(set) var unreadCount = 0
    private var readIds: Set<String> = []

    private var seenIds: Set<String> = []

    public init() {}

    public func append(
        _ notification: NotificationRecord,
        deliveryPolicy: NotificationDeliveryPolicy = .inboxOnly
    ) {
        let isNew = seenIds.insert(notification.id).inserted
        items.insert(notification, at: 0)
        if items.count > 200 {
            let evicted = items[200...].map(\.id)
            items.removeLast(items.count - 200)
            for id in evicted {
                seenIds.remove(id)
                readIds.remove(id)
            }
        }
        recomputeUnread()
        if isNew, localNotificationsEnabled, deliveryPolicy.shouldPostLocalNotification {
            onNew?(notification)
        }
    }

    /// Mark every currently-known notification for a workspace as read, so the
    /// workspace's badge clears. Called when the user opens that workspace.
    public func markWorkspaceSeen(_ workspaceId: String) {
        readIds.formUnion(WorkspaceNotificationTally.ids(in: items, forWorkspace: workspaceId))
        recomputeUnread()
    }

    public func markAllRead() {
        readIds.formUnion(items.map(\.id))
        recomputeUnread()
    }

    public func isUnread(_ id: String) -> Bool {
        !readIds.contains(id)
    }

    private func recomputeUnread() {
        unreadByWorkspace = WorkspaceNotificationTally.unreadCounts(records: items, readIds: readIds)
        unreadCount = unreadByWorkspace.values.reduce(0, +)
    }

    public func ingest(_ frame: PushFrame) {
        guard case .event(let event) = frame else { return }
        switch InboxNotification.effect(for: event) {
        case .card(let card):
            apply(card)
        case .markRead(let ids):
            readIds.formUnion(ids.filter { id in items.contains { $0.id == id } })
            recomputeUnread()
        case .remove(let ids):
            remove(ids)
        case .ignore:
            return
        }
    }

    /// A cmux notification keeps one card per id: a repeat updates it in place without a
    /// second banner. Agent needs-input cards keep the append behavior.
    private func apply(_ card: InboxCard) {
        remove(card.replacedIds)
        let id = card.record.id
        if card.isRead { readIds.insert(id) }
        if card.isCmuxNotification, let index = items.firstIndex(where: { $0.id == id }) {
            items[index] = card.record
            recomputeUnread()
            return
        }
        append(card.record, deliveryPolicy: NotificationDeliveryPolicy(card: card))
    }

    /// Removed ids stay in `seenIds` so a late repeat cannot raise a banner again.
    private func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let removed = Set(ids)
        items.removeAll { removed.contains($0.id) }
        readIds.subtract(removed)
        recomputeUnread()
    }
}

public enum NotificationDeliveryPolicy: Equatable {
    case inboxOnly
    case userInputRequired
    case userInitiatedTest
    case cmuxNotification

    var shouldPostLocalNotification: Bool {
        switch self {
        case .inboxOnly:
            return false
        case .userInputRequired, .userInitiatedTest, .cmuxNotification:
            return true
        }
    }

    init(event: EventFrame) {
        self = InboxNotification.requiresUserInput(event) ? .userInputRequired : .inboxOnly
    }

    init(card: InboxCard) {
        if card.isRead {
            self = .inboxOnly
        } else if card.requiresUserInput {
            self = .userInputRequired
        } else {
            self = card.isCmuxNotification ? .cmuxNotification : .inboxOnly
        }
    }
}
