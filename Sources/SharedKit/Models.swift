import Foundation

public struct Workspace: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var surfaces: [Surface]
    public var lastActivity: Int64
    public init(id: String, name: String, surfaces: [Surface], lastActivity: Int64) {
        self.id = id; self.name = name; self.surfaces = surfaces; self.lastActivity = lastActivity
    }
}

public struct Surface: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var cols: Int
    public var rows: Int
    public var lastActivity: Int64
    public init(id: String, title: String, cols: Int, rows: Int, lastActivity: Int64) {
        self.id = id; self.title = title; self.cols = cols; self.rows = rows; self.lastActivity = lastActivity
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
