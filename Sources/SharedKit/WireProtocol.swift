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
    enum CodingKeys: String, CodingKey {
        case surfaceId = "surface_id", rev, rows, cols, rowsCount, cursor
    }
}

public struct ScreenDiff: Codable, Sendable, Equatable {
    public var surfaceId: String
    public var rev: Int
    public var ops: [DiffOp]
    enum CodingKeys: String, CodingKey { case surfaceId = "surface_id", rev, ops }
}

public struct ScreenChecksum: Codable, Sendable, Equatable {
    public var surfaceId: String
    public var rev: Int
    public var hash: String
    enum CodingKeys: String, CodingKey { case surfaceId = "surface_id", rev, hash }
}

public struct EventFrame: Codable, Sendable, Equatable {
    public var category: EventCategory
    public var name: String
    public var payload: JSONValue
}

public struct PingFrame: Codable, Sendable, Equatable {
    public var ts: Int64
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
