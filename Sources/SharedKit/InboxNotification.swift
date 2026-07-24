import Foundation

public enum InboxNotification {
    public static func isInboxEvent(_ event: EventFrame) -> Bool {
        event.isInboxEvent
    }

    public static func record(from event: EventFrame, now: Int64 = Int64(Date().timeIntervalSince1970)) -> NotificationRecord? {
        guard event.isInboxEvent else { return nil }
        if let data = try? SharedKitJSON.deterministicEncoder.encode(event.payload),
           let decoded = try? SharedKitJSON.snakeCaseDecoder.decode(NotificationRecord.self, from: data)
        {
            return decoded
        }

        guard case .object(let payload) = event.payload else { return nil }
        let workspaceId = payload.stringValue(for: "workspace_id")
            ?? payload.stringValue(for: "workspaceId")
            ?? payload.stringValue(for: "workspaceID")
            ?? payload.stringValue(for: "workspace")
            ?? "unknown"
        let title = payload.stringValue(for: "title")
            ?? payload.stringValue(for: "headline")
            ?? event.titleFallback
        let body = payload.stringValue(for: "body")
            ?? payload.stringValue(for: "message")
            ?? payload.stringValue(for: "text")
            ?? payload.stringValue(for: "summary")
            ?? payload.stringValue(for: "reason")
            ?? payload.stringValue(for: "status")
            ?? payload.stringValue(for: "prompt")
            ?? payload.nestedStringValue(["details", "message"])
            ?? payload.nestedStringValue(["details", "body"])
            ?? title
        let surfaceId = payload.stringValue(for: "surface_id")
            ?? payload.stringValue(for: "surfaceId")
            ?? payload.stringValue(for: "surfaceID")
            ?? payload.stringValue(for: "surface")
        let id = payload.stringValue(for: "id")
            ?? payload.stringValue(for: "notification_id")
            ?? payload.stringValue(for: "notificationId")
            ?? payload.stringValue(for: "event_id")
            ?? payload.stringValue(for: "eventId")
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
            subtitle: payload.stringValue(for: "subtitle")
                ?? payload.stringValue(for: "workspace_title")
                ?? payload.stringValue(for: "workspaceTitle")
                ?? payload.stringValue(for: "surface_title")
                ?? payload.stringValue(for: "surfaceTitle"),
            body: body,
            ts: payload.intValue(for: "ts") ?? now,
            threadId: payload.stringValue(for: "thread_id")
                ?? payload.stringValue(for: "threadId")
                ?? "workspace-\(workspaceId)"
        )
    }
}

private extension EventFrame {
    var isInboxEvent: Bool {
        isNotificationEvent || isNeedsInputEvent
    }

    var isNotificationEvent: Bool {
        category == .notification || name == "notification.created"
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
        case "notification.created": return "cmux 알림"
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
