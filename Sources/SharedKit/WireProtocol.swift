import Foundation

// MARK: - Hello (client → server, the very first WS frame)

public struct HelloFrame: Codable, Sendable, Equatable {
    public var deviceId: String
    public var appVersion: String
    public var protocolVersion: Int
    public init(deviceId: String, appVersion: String, protocolVersion: Int) {
        self.deviceId = deviceId; self.appVersion = appVersion; self.protocolVersion = protocolVersion
    }
}

// MARK: - Server-pushed payloads (no rpc id)

public struct ScreenFull: Codable, Sendable, Equatable {
    public var surfaceId: String
    public var rev: Int
    public var rows: [String]
    public var cols: Int
    public var rowsCount: Int
    public var cursor: CursorPos
    public init(surfaceId: String, rev: Int, rows: [String], cols: Int, rowsCount: Int, cursor: CursorPos) {
        self.surfaceId = surfaceId; self.rev = rev; self.rows = rows
        self.cols = cols; self.rowsCount = rowsCount; self.cursor = cursor
    }
    enum CodingKeys: String, CodingKey {
        case surfaceId = "surface_id", rev, rows, cols, rowsCount, cursor
    }
}

public struct ScreenDiff: Codable, Sendable, Equatable {
    public var surfaceId: String
    public var rev: Int
    public var ops: [DiffOp]
    public init(surfaceId: String, rev: Int, ops: [DiffOp]) {
        self.surfaceId = surfaceId; self.rev = rev; self.ops = ops
    }
    enum CodingKeys: String, CodingKey { case surfaceId = "surface_id", rev, ops }
}

public struct ScreenChecksum: Codable, Sendable, Equatable {
    public var surfaceId: String
    public var rev: Int
    public var hash: String
    public init(surfaceId: String, rev: Int, hash: String) {
        self.surfaceId = surfaceId; self.rev = rev; self.hash = hash
    }
    enum CodingKeys: String, CodingKey { case surfaceId = "surface_id", rev, hash }
}

public struct EventFrame: Codable, Sendable, Equatable {
    public var category: EventCategory
    public var name: String
    public var payload: JSONValue
    public init(category: EventCategory, name: String, payload: JSONValue) {
        self.category = category; self.name = name; self.payload = payload
    }
}

public struct PingFrame: Codable, Sendable, Equatable {
    public var ts: Int64
    public init(ts: Int64) { self.ts = ts }
}

// MARK: - Discriminated union over the `type` field

public enum PushFrame: Sendable, Equatable {
    case screenFull(ScreenFull)
    case screenDiff(ScreenDiff)
    case screenChecksum(ScreenChecksum)
    case event(EventFrame)
    case ping(PingFrame)
    case pong(PingFrame)
}

extension PushFrame: Codable {
    private enum K: String, CodingKey { case type }
    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        let typed  = try decoder.container(keyedBy: K.self)
        switch try typed.decode(String.self, forKey: .type) {
        case "screen.full":     self = .screenFull(try single.decode(ScreenFull.self))
        case "screen.diff":     self = .screenDiff(try single.decode(ScreenDiff.self))
        case "screen.checksum": self = .screenChecksum(try single.decode(ScreenChecksum.self))
        case "event":           self = .event(try single.decode(EventFrame.self))
        case "ping":            self = .ping(try single.decode(PingFrame.self))
        case "pong":            self = .pong(try single.decode(PingFrame.self))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: typed,
                debugDescription: "Unknown push frame type: \(other)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var typed = encoder.container(keyedBy: K.self)
        switch self {
        case .screenFull(let f):
            try typed.encode("screen.full", forKey: .type)
            try f.encode(to: encoder)
        case .screenDiff(let f):
            try typed.encode("screen.diff", forKey: .type)
            try f.encode(to: encoder)
        case .screenChecksum(let f):
            try typed.encode("screen.checksum", forKey: .type)
            try f.encode(to: encoder)
        case .event(let f):
            try typed.encode("event", forKey: .type)
            try f.encode(to: encoder)
        case .ping(let f):
            try typed.encode("ping", forKey: .type)
            try f.encode(to: encoder)
        case .pong(let f):
            try typed.encode("pong", forKey: .type)
            try f.encode(to: encoder)
        }
    }
}
