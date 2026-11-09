import Foundation

/// What one pushed event does to the inbox.
public enum InboxEventEffect: Sendable, Equatable {
    /// A new or updated inbox card.
    case card(InboxCard)
    /// Existing cards that became read.
    case markRead(ids: [String])
    /// Existing cards that went away.
    case remove(ids: [String])
    /// Not an inbox event (internal audit, state with no id, unrelated category).
    case ignore
}

public struct InboxCard: Sendable, Equatable {
    public var record: NotificationRecord
    /// `true` for a cmux `notification.created` store notification.
    public var isCmuxNotification: Bool
    public var requiresUserInput: Bool
    /// Cards this notification replaces (`replaced_notification_ids`).
    public var replacedIds: [String]
    public var isRead: Bool

    public init(record: NotificationRecord, isCmuxNotification: Bool, requiresUserInput: Bool,
                replacedIds: [String], isRead: Bool) {
        self.record = record; self.isCmuxNotification = isCmuxNotification
        self.requiresUserInput = requiresUserInput; self.replacedIds = replacedIds; self.isRead = isRead
    }
}

public enum InboxNotification {
    public static let createdEventName = "notification.created"
    public static let readEventName = "notification.read"
    public static let removedEventName = "notification.removed"
    /// Sent after `notification.clear_requested` when the Mac clears notifications; its
    /// `notification_ids` lists every card that went away.
    public static let clearedEventName = "notification.cleared"
    public static let requestedEventName = "notification.requested"
    /// Title a cmux notification gets when its content was not available (still redacted).
    public static let fallbackTitle = "cmux notification"

    public static func isInboxEvent(_ event: EventFrame) -> Bool {
        if case .card = effect(for: event, now: 0) { return true }
        return false
    }

    public static func requiresUserInput(_ event: EventFrame) -> Bool {
        event.isNeedsInputEvent
    }

    /// Classifies an event. Only `notification.created` and the agent needs-input heuristic
    /// make cards; `notification.read`/`notification.removed`/`notification.cleared` change
    /// existing cards; every other `notification.*` event (the `notification.requested` socket
    /// audit, `notification.clear_requested`, unknown names) is ignored.
    public static func effect(
        for event: EventFrame,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> InboxEventEffect {
        switch event.name {
        case createdEventName:
            guard let record = buildRecord(from: event, now: now) else { return .ignore }
            let payload = event.payloadObject
            return .card(InboxCard(
                record: record,
                isCmuxNotification: true,
                requiresUserInput: event.isNeedsInputEvent,
                replacedIds: payload?.stringArray(for: "replaced_notification_ids")
                    .filter { $0 != record.id } ?? [],
                isRead: payload?["is_read"] == .bool(true)
            ))
        case readEventName:
            guard let id = event.payloadObject?.notificationId else { return .ignore }
            return .markRead(ids: [id])
        case removedEventName:
            guard let id = event.payloadObject?.notificationId else { return .ignore }
            return .remove(ids: [id])
        case clearedEventName:
            let ids = event.payloadObject?.stringArray(for: "notification_ids") ?? []
            return ids.isEmpty ? .ignore : .remove(ids: ids)
        default:
            guard !event.name.hasPrefix("notification."), event.isNeedsInputEvent,
                  let record = buildRecord(from: event, now: now)
            else { return .ignore }
            return .card(InboxCard(
                record: record,
                isCmuxNotification: false,
                requiresUserInput: true,
                replacedIds: [],
                isRead: false
            ))
        }
    }

    public static func record(from event: EventFrame, now: Int64 = Int64(Date().timeIntervalSince1970)) -> NotificationRecord? {
        guard case .card(let card) = effect(for: event, now: now) else { return nil }
        return card.record
    }

    private static func buildRecord(from event: EventFrame, now: Int64) -> NotificationRecord? {
        if let data = try? SharedKitJSON.deterministicEncoder.encode(event.payload),
           let decoded = try? SharedKitJSON.snakeCaseDecoder.decode(NotificationRecord.self, from: data)
        {
            return decoded
        }

        guard case .object(let payload) = event.payload else { return nil }
        let workspaceId = payload.firstStringValue(forAny: [
            "workspace_id", "workspaceId", "workspaceID", "workspace",
        ]) ?? "unknown"
        let title = payload.firstStringValue(forAny: ["title", "headline"])
            ?? event.titleFallback
        // A cmux store notification without content (still redacted) has no body to show;
        // repeating the title would only duplicate it.
        let body = payload.firstStringValue(forAny: [
            "body", "message", "text", "summary", "reason", "status", "prompt",
        ])
            ?? payload.nestedStringValue(["details", "message"])
            ?? payload.nestedStringValue(["details", "body"])
            ?? (event.name == createdEventName ? "" : title)
        let surfaceId = payload.firstStringValue(forAny: [
            "surface_id", "surfaceId", "surfaceID", "surface",
        ])
        let id = payload.firstStringValue(forAny: [
            "id", "notification_id", "notificationId", "event_id", "eventId",
        ])
            ?? payload.nestedStringValue(["details", "id"])
            ?? (event.isNeedsInputEvent
                ? event.syntheticNeedsInputNotificationId(
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    title: title,
                    body: body
                )
                : UUID().uuidString)

        return NotificationRecord(
            id: id,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            title: title,
            subtitle: payload.firstStringValue(forAny: [
                "subtitle", "workspace_title", "workspaceTitle", "surface_title", "surfaceTitle",
                "tab_title",
            ]),
            body: body,
            ts: payload.intValue(for: "ts") ?? now,
            threadId: payload.firstStringValue(forAny: ["thread_id", "threadId"])
                ?? "workspace-\(workspaceId)"
        )
    }
}

private extension EventFrame {
    var payloadObject: [String: JSONValue]? {
        guard case .object(let object) = payload else { return nil }
        return object
    }

    var isNeedsInputEvent: Bool {
        let text = inboxSearchText
        let needsHuman = text.contains("needs input")
            || text.contains("waiting for your input")
            || text.contains("needs your attention")
            || text.contains("needs your approval")
            || text.contains("approval required")
            || text.contains("permission prompt")
        return needsHuman && (hasKnownAgentSource || isDirectNeedsInputEvent)
    }

    var hasKnownAgentSource: Bool {
        let text = inboxSearchText
        return text.contains("claude")
            || text.contains("codex")
            || text.contains("openai")
    }

    var isDirectNeedsInputEvent: Bool {
        let normalizedName = name
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return inboxSearchText.contains("needs input")
            || normalizedName.contains("needs input")
    }

    var inboxSearchText: String {
        var values = [category.rawValue, name]
        if case .object(let payload) = payload {
            for key in [
                "app", "source", "kind", "type", "status", "state", "reason",
                "title", "subtitle", "body", "message", "text", "summary",
                "workspace_title", "workspaceTitle", "surface_title", "surfaceTitle",
                "agent", "model", "role",
            ] {
                if let value = payload.stringValue(for: key) {
                    values.append(value)
                }
            }
            self.payload.appendStringLeaves(to: &values)
        }
        return values
            .joined(separator: " ")
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    var titleFallback: String {
        if isNeedsInputEvent { return "\(needsInputSourceName) needs input" }
        switch name {
        case InboxNotification.createdEventName: return InboxNotification.fallbackTitle
        default: return name
        }
    }

    var needsInputSourceName: String {
        let text = inboxSearchText
        if text.contains("codex") { return "Codex" }
        if text.contains("openai") { return "OpenAI" }
        if text.contains("claude") { return "Claude Code" }
        if category == .hook { return "cmux hook" }
        if category == .agent { return "Agent" }
        return "cmux"
    }

    func syntheticNeedsInputNotificationId(
        workspaceId: String,
        surfaceId: String?,
        title: String,
        body: String
    ) -> String {
        let raw = [name, workspaceId, surfaceId ?? "", title, body]
            .joined(separator: "|")
        let allowed = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return "-"
        }
        let slug = String(allowed)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "needs-input-\(slug.prefix(96))"
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func stringValue(for key: String) -> String? {
        guard case .string(let value)? = self[key], !value.isEmpty else { return nil }
        return value
    }

    // Returns the first non-empty string value among `keys`, in order. Replaces
    // long `?? stringValue(for:)` chains that overwhelm the Swift type-checker.
    func firstStringValue(forAny keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(for: key) { return value }
        }
        return nil
    }

    var notificationId: String? {
        firstStringValue(forAny: ["notification_id", "notificationId", "id"])
    }

    func stringArray(for key: String) -> [String] {
        guard case .array(let values)? = self[key] else { return [] }
        return values.compactMap { value in
            guard case .string(let string) = value, !string.isEmpty else { return nil }
            return string
        }
    }

    func intValue(for key: String) -> Int64? {
        switch self[key] {
        case .int(let value): return value
        case .double(let value): return Int64(value)
        case .string(let value): return Int64(value)
        default: return nil
        }
    }

    func nestedStringValue(_ keys: [String]) -> String? {
        guard let key = keys.first else { return nil }
        guard let value = self[key] else { return nil }
        if keys.count == 1 {
            guard case .string(let string) = value, !string.isEmpty else { return nil }
            return string
        }
        guard case .object(let object) = value else { return nil }
        return object.nestedStringValue(Array(keys.dropFirst()))
    }
}

private extension JSONValue {
    func appendStringLeaves(to values: inout [String]) {
        switch self {
        case .string(let value):
            if !value.isEmpty { values.append(value) }
        case .array(let array):
            for value in array {
                value.appendStringLeaves(to: &values)
            }
        case .object(let object):
            for value in object.values {
                value.appendStringLeaves(to: &values)
            }
        default:
            break
        }
    }
}
