import Foundation

/// Workspace as it crosses the relay → iOS boundary.
///
/// Slimmed v2 (2026-05-10): cmux's `workspace.list` does not expose `lastActivity`
/// or inline surfaces. We surface only the fields iOS actually renders. Sort by
/// `index` (cmux-defined ordering, mirrors `workspace:N` refs).
public struct Workspace: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var index: Int
    public init(id: String, name: String, index: Int) {
        self.id = id; self.name = name; self.index = index
    }
}

/// Surface as it crosses the relay → iOS boundary.
///
/// Slimmed v2 (2026-05-10): cmux's `surface.list` does not expose terminal grid
/// dimensions or `lastActivity`. Cols/rows of the live buffer come from
/// `surface.read_text` responses on the server side.
public struct Surface: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var index: Int
    /// cmux surface kind (`terminal`, `browser`, `markdown`, or a future value).
    /// `nil` means the producer predates surface kinds; omitted from the wire when `nil`.
    public var type: String?
    public init(id: String, title: String, index: Int, type: String? = nil) {
        self.id = id; self.title = title; self.index = index; self.type = type
    }

    /// Whether the surface can be subscribed as a terminal. Unknown kinds from older
    /// relays (`nil`) keep the historical terminal behavior.
    public var isTerminal: Bool { type == nil || type == "terminal" }
}

public struct NotificationRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var workspaceId: String
    public var surfaceId: String?
    public var title: String
    public var subtitle: String?
    public var body: String
    public var ts: Int64
    public var threadId: String
    public init(id: String, workspaceId: String, surfaceId: String?, title: String,
                subtitle: String?, body: String, ts: Int64, threadId: String) {
        self.id = id; self.workspaceId = workspaceId; self.surfaceId = surfaceId
        self.title = title; self.subtitle = subtitle; self.body = body
        self.ts = ts; self.threadId = threadId
    }
}

public struct BootInfo: Codable, Sendable, Equatable {
    public var bootId: String
    public var startedAt: Int64
    public init(bootId: String, startedAt: Int64) { self.bootId = bootId; self.startedAt = startedAt }
}

public enum EventCategory: String, Codable, Sendable, CaseIterable {
    case workspace, surface, notification, system, agent, hook, unknown

    public static var allCases: [EventCategory] {
        [.workspace, .surface, .notification, .system, .agent, .hook]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = EventCategory(rawValue: rawValue) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
