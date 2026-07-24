import Observation
import SharedKit

@MainActor
@Observable
public final class NotificationStore {
    public var items: [NotificationRecord] = []
    public var onNew: (@MainActor (NotificationRecord) -> Void)?

    public private(set) var unreadByWorkspace: [String: Int] = [:]
    public private(set) var unreadCount = 0
    private var readIds: Set<String> = []

    private var seenIds: Set<String> = []

    public init() {}

    public func append(_ notification: NotificationRecord) {
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
        if isNew { onNew?(notification) }
    }

    /// Mark every currently-known notification for a workspace as read, so the
    /// workspace's badge clears. Called when the user opens that workspace.
    public func markWorkspaceSeen(_ workspaceId: String) {
        readIds.formUnion(WorkspaceNotificationTally.ids(in: items, forWorkspace: workspaceId))
        recomputeUnread()
    }

    private func recomputeUnread() {
        unreadByWorkspace = WorkspaceNotificationTally.unreadCounts(records: items, readIds: readIds)
        unreadCount = unreadByWorkspace.values.reduce(0, +)
    }

    public func ingest(_ frame: PushFrame) {
        guard case .event(let event) = frame else { return }
        guard let notification = InboxNotification.record(from: event) else { return }
        append(notification)
    }
}
