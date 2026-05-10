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
    public init(id: String, title: String, index: Int) {
        self.id = id; self.title = title; self.index = index
    }
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
    case workspace, surface, notification, system
}
