import Foundation
import AsyncHTTPClient
import NIOCore

/// Resolved tailnet identity for the peer behind a TCP connection.
public struct PeerIdentity: Equatable, Sendable {
    public var loginName: String   // e.g. "alice@example.com"
    public var hostname: String    // e.g. "iPhone-15-Pro" (Hostinfo.Hostname)
    public var os: String          // e.g. "iOS"           (Hostinfo.OS)
    public var nodeKey: String     // tailnet node key, e.g. "nodekey:abc..."

    public init(loginName: String, hostname: String, os: String, nodeKey: String) {
        self.loginName = loginName; self.hostname = hostname
        self.os = os; self.nodeKey = nodeKey
    }
}

/// Resolves a connecting peer's tailnet identity. Spec section 7.1.
public protocol AuthService: Sendable {
    func whois(remoteAddr: String) async throws -> PeerIdentity

    /// The relay host's own tailnet login, if it has one — used to
    /// auto-authorise the operator's own devices for pairing. Returns nil for
    /// tagged/headless nodes (no user) or when tailscaled can't be reached.
    func selfLogin() async -> String?
}

public extension AuthService {
    func selfLogin() async -> String? { nil }
}

/// Test fake — keyed by IP (port stripped).
public final class MockAuthService: AuthService, @unchecked Sendable {
    public var peers: [String: PeerIdentity]
    public init(peers: [String: PeerIdentity]) { self.peers = peers }

    public func whois(remoteAddr: String) async throws -> PeerIdentity {
        guard let p = peers[stripPort(remoteAddr)] else {
            throw RelayError.unauthorized(remoteAddr)
        }
        return p
    }
}

/// Production auth backend — talks to the host's `tailscaled` over its local
/// Unix socket (`/var/run/tailscaled.socket` on linux,
/// `/var/run/tailscale/tailscaled.sock` on macOS open-source builds) and
/// calls the LocalAPI `/localapi/v0/whois` endpoint to resolve the peer.
///
/// Requires async-http-client 1.21+ for `http+unix://` URL support. The
/// `Sec-Tailscale: localapi` header is required by tailscaled's CSRF guard.
public final class TailscaledLocalAuth: AuthService {
    public typealias CLIWhois = @Sendable (String) async throws -> Data

    public let socketPath: String
    public let httpClient: HTTPClient
    private let cliWhois: CLIWhois
    private let ownsHTTPClient: Bool

    public init(socketPath: String = "/var/run/tailscaled.socket",
                httpClient: HTTPClient = HTTPClient(eventLoopGroupProvider: .singleton),
                ownsHTTPClient: Bool = true,
                cliWhois: CLIWhois? = nil)
    {
        self.socketPath = socketPath
        self.httpClient = httpClient
        self.ownsHTTPClient = ownsHTTPClient
        self.cliWhois = cliWhois ?? { addr in
            try await TailscaledLocalAuth.runTailscaleWhoisCLI(addr: addr)
        }
    }

    deinit {
        if ownsHTTPClient {
            try? httpClient.syncShutdown()
        }
    }

    public func whois(remoteAddr: String) async throws -> PeerIdentity {
        let addr = stripPort(remoteAddr)
        if FileManager.default.fileExists(atPath: socketPath) {
            do {
                return try await whoisViaLocalAPI(addr: addr)
            } catch {
                // Some macOS Tailscale distributions do not expose a
                // tailscaled Unix socket even though `tailscale whois --json`
                // works. Fall through to the CLI path so operator-side smoke
                // tests work across both open-source and App Store installs.
            }
        }
        do {
            return try Self.parseWhoisResponse(try await cliWhois(addr))
        } catch {
            throw RelayError.unauthorized(remoteAddr)
        }
    }

    private func whoisViaLocalAPI(addr: String) async throws -> PeerIdentity {
        let url = "http+unix://localhost\(socketPath)/localapi/v0/whois?addr=\(addr)"
        var req = HTTPClientRequest(url: url)
        req.headers.add(name: "Sec-Tailscale", value: "localapi")
        let resp = try await httpClient.execute(req, timeout: .seconds(2))
        guard resp.status == .ok else { throw RelayError.unauthorized(addr) }
        let body = try await resp.body.collect(upTo: 1 << 20)
        return try Self.parseWhoisResponse(Data(buffer: body))
    }

    private static func runTailscaleWhoisCLI(addr: String) async throws -> Data {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["tailscale", "whois", "--json", addr]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus == 0 {
                return data
            }
            throw RelayError.unauthorized(addr)
        }.value
    }

    /// The relay host's own tailnet login (e.g. `you@example.com`), resolved
    /// from `tailscale status`. nil for tagged/headless nodes or if tailscaled
    /// is unreachable. Mirrors `whois`: LocalAPI socket first, CLI fallback.
    public func selfLogin() async -> String? {
        let data: Data
        if FileManager.default.fileExists(atPath: socketPath),
           let viaAPI = try? await statusViaLocalAPI() {
            data = viaAPI
        } else if let viaCLI = try? await Self.runTailscaleStatusCLI() {
            data = viaCLI
        } else {
            return nil
        }
        return Self.parseSelfLogin(data)
    }

    private func statusViaLocalAPI() async throws -> Data {
        let url = "http+unix://localhost\(socketPath)/localapi/v0/status"
        var req = HTTPClientRequest(url: url)
        req.headers.add(name: "Sec-Tailscale", value: "localapi")
        let resp = try await httpClient.execute(req, timeout: .seconds(2))
        guard resp.status == .ok else { throw RelayError.unauthorized("status") }
        let body = try await resp.body.collect(upTo: 8 << 20)
        return Data(buffer: body)
    }

    private static func runTailscaleStatusCLI() async throws -> Data {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["tailscale", "status", "--json"]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            // `status --json` can exceed the 64KB pipe buffer, so drain before
            // waiting to avoid a deadlock (the tiny `whois` payload can't).
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return data
            }
            throw RelayError.unauthorized("status")
        }.value
    }

    /// Extracts the host's own login from a `tailscale status --json` /
    /// LocalAPI `/v0/status` payload: `Self.UserID` indexes the `User` map.
    /// Returns nil for tagged nodes (UserID 0 / no matching user) or malformed
    /// output. Visible to tests.
    public static func parseSelfLogin(_ data: Data) -> String? {
        struct Status: Decodable {
            struct SelfNode: Decodable { let UserID: Int64? }
            struct UserProfile: Decodable { let LoginName: String? }
            let selfNode: SelfNode?
            let users: [String: UserProfile]?
            enum CodingKeys: String, CodingKey {
                case selfNode = "Self"
                case users = "User"
            }
        }
        guard let s = try? JSONDecoder().decode(Status.self, from: data),
              let uid = s.selfNode?.UserID, uid != 0,
              let login = s.users?[String(uid)]?.LoginName,
              !login.isEmpty else { return nil }
        return login
    }

    /// Decodes a `tailscaled` `/localapi/v0/whois` response. Visible to tests.
    /// Tailscale's response keeps PascalCase field names (`Node`, `UserProfile`,
    /// `LoginName`, `Hostinfo`, `Key`); we mirror that here so changes upstream
    /// surface as compile errors rather than silent zeroes.
    public static func parseWhoisResponse(_ data: Data) throws -> PeerIdentity {
        struct Whois: Decodable {
            struct UserProfile: Decodable { let LoginName: String }
            struct Node: Decodable {
                let Key: String
                let Hostinfo: Hostinfo?
                struct Hostinfo: Decodable {
                    let OS: String?
                    let Hostname: String?
                }
            }
            let UserProfile: UserProfile
            let Node: Node
        }
        let w = try JSONDecoder().decode(Whois.self, from: data)
        return PeerIdentity(
            loginName: w.UserProfile.LoginName,
            hostname: w.Node.Hostinfo?.Hostname ?? "",
            os: w.Node.Hostinfo?.OS ?? "",
            nodeKey: w.Node.Key
        )
    }
}

/// Strip the trailing `:port` (or `]:port` on bracketed IPv6) from a remote
/// address that NIO hands us, since tailscaled's `whois` wants just the IP.
private func stripPort(_ addr: String) -> String {
    if let bracket = addr.lastIndex(of: "]") {
        // bracketed IPv6: "[fd7a::1]:1234" → "fd7a::1"
        let head = addr[addr.startIndex...bracket]
        return String(head.dropFirst().dropLast())
    }
    if let colon = addr.lastIndex(of: ":"),
       // single-colon IPv4 ("1.2.3.4:5") only — un-bracketed IPv6 has many colons.
       addr.filter({ $0 == ":" }).count == 1 {
        return String(addr[addr.startIndex..<colon])
    }
    return addr
}
