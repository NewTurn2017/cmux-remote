import Foundation

/// A type-erased JSON value used for `params`/`result` payloads where the
/// shape is method-specific. Lives in SharedKit so both ends share a parser.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self)            { self = .bool(b);   return }
        if let i = try? c.decode(Int64.self)           { self = .int(i);    return }
        if let d = try? c.decode(Double.self)          { self = .double(d); return }
        if let s = try? c.decode(String.self)          { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self)     { self = .array(a);  return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let v):    try c.encode(v)
        case .int(let v):     try c.encode(v)
        case .double(let v):  try c.encode(v)
        case .string(let v):  try c.encode(v)
        case .array(let v):   try c.encode(v)
        case .object(let v):  try c.encode(v)
        }
    }
}

public struct RPCRequest: Codable, Sendable, Equatable {
    public var id: String
    public var method: String
    public var params: JSONValue
    public init(id: String, method: String, params: JSONValue) {
        self.id = id; self.method = method; self.params = params
    }
}

public struct RPCError: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var data: JSONValue?
    public init(code: String, message: String, data: JSONValue? = nil) {
        self.code = code; self.message = message; self.data = data
    }
}

public struct RPCResponse: Codable, Sendable, Equatable {
    public var id: String
    /// Optional on the wire: cmux omits `ok` on success, sends `ok: false` on error.
    /// Treat absent + no error as success. Use `isOk` for the canonical check.
    public var ok: Bool?
    public var result: JSONValue?
    public var error: RPCError?
    public init(id: String, ok: Bool? = nil, result: JSONValue? = nil, error: RPCError? = nil) {
        self.id = id; self.ok = ok; self.result = result; self.error = error
    }

    public var isOk: Bool { (ok ?? true) && error == nil }
}
