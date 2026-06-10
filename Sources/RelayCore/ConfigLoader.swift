import Foundation

/// `relay.json` schema. Spec section 7.3.
public struct RelayConfig: Codable, Equatable, Sendable {
    public struct APNs: Codable, Equatable, Sendable {
        public var keyPath: String
        public var keyId: String
        public var teamId: String
        public var topic: String
        public var env: String
        enum CodingKeys: String, CodingKey {
            case keyPath = "key_path", keyId = "key_id", teamId = "team_id", topic, env
        }
        public init(keyPath: String, keyId: String, teamId: String, topic: String, env: String) {
            self.keyPath = keyPath; self.keyId = keyId; self.teamId = teamId
            self.topic = topic; self.env = env
        }
    }

    public struct Snippet: Codable, Equatable, Sendable {
        public var label: String
        public var text: String
        public init(label: String, text: String) { self.label = label; self.text = text }
    }

    public var listen: String
    public var allowLogin: [String]
    public var apns: APNs
    public var snippets: [Snippet]
    public var defaultFps: Int
    public var idleFps: Int

    enum CodingKeys: String, CodingKey {
        case listen, allowLogin = "allow_login", apns, snippets,
             defaultFps = "default_fps", idleFps = "idle_fps"
    }

    public init(listen: String, allowLogin: [String], apns: APNs,
                snippets: [Snippet], defaultFps: Int, idleFps: Int)
    {
        self.listen = listen; self.allowLogin = allowLogin; self.apns = apns
        self.snippets = snippets; self.defaultFps = defaultFps; self.idleFps = idleFps
    }

    /// Baseline config used to fill any key omitted from `relay.json`. The
    /// installer (and the documented happy path) writes only a handful of
    /// keys, so decoding must tolerate the rest being absent rather than
    /// throwing `keyNotFound` — which crash-loops the daemon at startup and
    /// reads to users as "can't connect" (issue #3). Push stays disabled until
    /// a real `apns` block is supplied; an empty `allow_login` authorises
    /// nobody until the operator lists their tailnet login.
    public static let defaults = RelayConfig(
        listen: "0.0.0.0:4399",
        allowLogin: [],
        apns: .init(keyPath: "", keyId: "", teamId: "", topic: "", env: "sandbox"),
        snippets: [],
        defaultFps: 15,
        idleFps: 5
    )

    /// Tolerant decoder: present keys are decoded normally (a malformed value
    /// still throws), but any *omitted* key falls back to ``defaults``. This is
    /// what lets the minimal default `relay.json` boot the relay.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RelayConfig.defaults
        self.listen     = try c.decodeIfPresent(String.self,    forKey: .listen)     ?? d.listen
        self.allowLogin = try c.decodeIfPresent([String].self,  forKey: .allowLogin) ?? d.allowLogin
        self.apns       = try c.decodeIfPresent(APNs.self,      forKey: .apns)       ?? d.apns
        self.snippets   = try c.decodeIfPresent([Snippet].self, forKey: .snippets)   ?? d.snippets
        self.defaultFps = try c.decodeIfPresent(Int.self,       forKey: .defaultFps) ?? d.defaultFps
        self.idleFps    = try c.decodeIfPresent(Int.self,       forKey: .idleFps)    ?? d.idleFps
    }

    public static func decode(jsonString: String) throws -> RelayConfig {
        try JSONDecoder().decode(RelayConfig.self, from: Data(jsonString.utf8))
    }

    /// Returns a copy with `login` appended to `allowLogin`. Idempotent and
    /// nil/empty-safe, so the relay can fold in its own tailnet login without
    /// duplicating an already-listed operator or reacting to a missing one.
    public func authorizing(login: String?) -> RelayConfig {
        guard let login, !login.isEmpty, !allowLogin.contains(login) else { return self }
        var copy = self
        copy.allowLogin.append(login)
        return copy
    }
}

/// Holds the current `relay.json` snapshot and reloads it on demand.
///
/// `@unchecked Sendable` is acceptable here because reads of `current` are
/// stable references to a value type and writes happen only inside `reload()`.
/// M3 task 11 (HTTPServer) wires `DispatchSource.makeFileSystemObjectSource`
/// + SIGHUP to call `reload()`; if multiple writers ever race, swap to an
/// actor at that point.
public final class ConfigStore: @unchecked Sendable {
    public let url: URL
    public private(set) var current: RelayConfig

    public init(url: URL) {
        self.url = url
        self.current = .defaults
    }

    public func reload() throws {
        let data = try Data(contentsOf: url)
        self.current = try JSONDecoder().decode(RelayConfig.self, from: data)
    }
}
