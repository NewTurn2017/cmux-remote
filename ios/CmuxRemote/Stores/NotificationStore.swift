import Foundation
import Observation
import SharedKit

@MainActor
@Observable
public final class NotificationStore {
    public var items: [NotificationRecord] = []
    public var onNew: (@MainActor (NotificationRecord) -> Void)?

    private var seenIds: Set<String> = []

    public init() {}

    public func append(_ notification: NotificationRecord) {
        let isNew = seenIds.insert(notification.id).inserted
        items.insert(notification, at: 0)
        if items.count > 200 {
            let evicted = items[200...].map(\.id)
            items.removeLast(items.count - 200)
            for id in evicted { seenIds.remove(id) }
        }
        if isNew { onNew?(notification) }
    }

    public func ingest(_ frame: PushFrame) {
        guard case .event(let event) = frame, event.isNotificationEvent else { return }
        guard let notification = NotificationRecord(event: event) else { return }
        append(notification)
    }
}

private extension EventFrame {
    var isNotificationEvent: Bool {
        category == .notification || name == "notification.created"
    }
}

private extension NotificationRecord {
    init?(event: EventFrame) {
        if let data = try? SharedKitJSON.deterministicEncoder.encode(event.payload),
           let decoded = try? SharedKitJSON.snakeCaseDecoder.decode(NotificationRecord.self, from: data)
        {
            self = decoded
            return
        }

        guard case .object(let payload) = event.payload else { return nil }
        let workspaceId = payload.stringValue(for: "workspace_id")
            ?? payload.stringValue(for: "workspaceId")
            ?? payload.stringValue(for: "workspace")
            ?? "unknown"
        let title = payload.stringValue(for: "title")
            ?? event.titleFallback
        let body = payload.stringValue(for: "body")
            ?? payload.stringValue(for: "message")
            ?? payload.stringValue(for: "text")
            ?? payload.stringValue(for: "summary")
            ?? title

        self.init(
            id: payload.stringValue(for: "id") ?? UUID().uuidString,
            workspaceId: workspaceId,
            surfaceId: payload.stringValue(for: "surface_id") ?? payload.stringValue(for: "surfaceId"),
            title: title,
            subtitle: payload.stringValue(for: "subtitle")
                ?? payload.stringValue(for: "workspace_title")
                ?? payload.stringValue(for: "workspaceTitle"),
            body: body,
            ts: payload.intValue(for: "ts") ?? Int64(Date().timeIntervalSince1970),
            threadId: payload.stringValue(for: "thread_id")
                ?? payload.stringValue(for: "threadId")
                ?? "workspace-\(workspaceId)"
        )
    }
}

private extension EventFrame {
    var titleFallback: String {
        switch name {
        case "notification.created": return "cmux 알림"
        default: return name
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func stringValue(for key: String) -> String? {
        guard case .string(let value)? = self[key], !value.isEmpty else { return nil }
        return value
    }

    func intValue(for key: String) -> Int64? {
        switch self[key] {
        case .int(let value): return value
        case .double(let value): return Int64(value)
        case .string(let value): return Int64(value)
        default: return nil
        }
    }
}
