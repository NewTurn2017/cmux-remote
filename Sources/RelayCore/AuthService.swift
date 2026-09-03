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

/// Failures from the local Tailscale identity service. Callers must keep
/// `peerNotFound` separate from service failures: the first is an authorization
/// denial, while the others can recover after Tailscale finishes starting.
public enum TailnetIdentityError: Error, Equatable, Sendable {
    case peerNotFound
    case serviceUnavailable
    case invalidResponse
}

/// Resolves a connecting peer's tailnet identity. Spec section 7.1.
public protocol AuthService: Sendable {
    func whois(remoteAddr: String) async throws -> PeerIdentity

    /// The relay host's current tailnet login. A tagged node returns nil.
    /// Tailscale transport or decoding failures throw so callers can expose a
    /// retryable state instead of misreporting a permanent policy denial.
    func selfLogin() async throws -> String?
}

public extension AuthService {
    func selfLogin() async throws -> String? { nil }
}

/// Test fake, keyed by IP after any port is stripped.
public final class MockAuthService: AuthService, @unchecked Sendable {
    public var peers: [String: PeerIdentity]
    public var whoisError: TailnetIdentityError?
    public var selfLoginValue: String?
    public var selfLoginError: TailnetIdentityError?

    public init(
        peers: [String: PeerIdentity],
        whoisError: TailnetIdentityError? = nil,
        selfLogin: String? = nil,
        selfLoginError: TailnetIdentityError? = nil
    ) {
        self.peers = peers
        self.whoisError = whoisError
        self.selfLoginValue = selfLogin
        self.selfLoginError = selfLoginError
    }

    public func whois(remoteAddr: String) async throws -> PeerIdentity {
        if let whoisError { throw whoisError }
        guard let peer = peers[stripPort(remoteAddr)] else {
            throw TailnetIdentityError.peerNotFound
        }
        return peer
    }

    public func selfLogin() async throws -> String? {
        if let selfLoginError { throw selfLoginError }
        return selfLoginValue
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
            } catch TailnetIdentityError.peerNotFound {
                throw TailnetIdentityError.peerNotFound
            } catch {
                // App Store and standalone macOS variants can expose a socket
                // that is temporarily unavailable while their network
                // extension restarts. The CLI reaches the GUI/XPC path.
            }
        }
        do {
            return try Self.parseWhoisResponse(try await cliWhois(addr))
        } catch let error as TailnetIdentityError {
            throw error
        } catch {
            throw TailnetIdentityError.serviceUnavailable
        }
    }

    private func whoisViaLocalAPI(addr: String) async throws -> PeerIdentity {
        let url = "http+unix://localhost\(socketPath)/localapi/v0/whois?addr=\(addr)"
        var req = HTTPClientRequest(url: url)
        req.headers.add(name: "Sec-Tailscale", value: "localapi")
        let resp = try await httpClient.execute(req, timeout: .seconds(2))
        if resp.status == .notFound { throw TailnetIdentityError.peerNotFound }
        guard resp.status == .ok else { throw TailnetIdentityError.serviceUnavailable }
        let body = try await resp.body.collect(upTo: 1 << 20)
        do {
            return try Self.parseWhoisResponse(Data(buffer: body))
        } catch {
            throw TailnetIdentityError.invalidResponse
        }
    }

    private static func runTailscaleWhoisCLI(addr: String) async throws -> Data {
        try await Task.detached {
            let output = try runTailscaleCLI(arguments: ["whois", "--json", addr])
            if output.terminationStatus == 0 {
                return output.stdout
            }
            let errorText = String(decoding: output.stderr, as: UTF8.self)
            if errorText.contains("peer not found") {
                throw TailnetIdentityError.peerNotFound
            }
            throw TailnetIdentityError.serviceUnavailable
        }.value
    }

    /// The relay host's own tailnet login (e.g. `you@example.com`), resolved
    /// from `tailscale status`. nil for tagged/headless nodes or if tailscaled
    /// is unreachable. Mirrors `whois`: LocalAPI socket first, CLI fallback.
    public func selfLogin() async throws -> String? {
        let data: Data
        if FileManager.default.fileExists(atPath: socketPath) {
            do {
                data = try await statusViaLocalAPI()
            } catch {
                data = try await Self.runTailscaleStatusCLI()
            }
        } else {
            data = try await Self.runTailscaleStatusCLI()
        }
        return try Self.parseSelfLogin(data)
    }

    private func statusViaLocalAPI() async throws -> Data {
        let url = "http+unix://localhost\(socketPath)/localapi/v0/status"
        var req = HTTPClientRequest(url: url)
        req.headers.add(name: "Sec-Tailscale", value: "localapi")
        let resp = try await httpClient.execute(req, timeout: .seconds(2))
        guard resp.status == .ok else { throw TailnetIdentityError.serviceUnavailable }
        let body = try await resp.body.collect(upTo: 8 << 20)
        return Data(buffer: body)
    }

    private static func runTailscaleStatusCLI() async throws -> Data {
        try await Task.detached {
            let output = try runTailscaleCLI(arguments: ["status", "--json"])
            guard output.terminationStatus == 0 else {
                throw TailnetIdentityError.serviceUnavailable
            }
            return output.stdout
        }.value
    }

    static func resolveTailscaleCLI(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appExecutablePath: String = "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        fileManager: FileManager = .default
    ) -> String? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent("tailscale", isDirectory: false)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return fileManager.isExecutableFile(atPath: appExecutablePath)
            ? appExecutablePath
            : nil
    }

    private static func runTailscaleCLI(
        arguments: [String]
    ) throws -> TailscaleCLIProcessOutput {
        guard let executablePath = resolveTailscaleCLI() else {
            throw TailnetIdentityError.serviceUnavailable
        }
        let environment = ProcessInfo.processInfo.environment.merging(
            ["TAILSCALE_BE_CLI": "1"],
            uniquingKeysWith: { _, forcedValue in forcedValue }
        )
        do {
            return try TailscaleCLIProcessRunner.run(
                executableURL: URL(fileURLWithPath: executablePath),
                arguments: arguments,
                environment: environment
            )
        } catch {
            throw TailnetIdentityError.serviceUnavailable
        }
    }

    /// Extracts the host's own login from a `tailscale status --json` /
    /// LocalAPI `/v0/status` payload: `Self.UserID` indexes the `User` map.
    /// Returns nil for tagged nodes (UserID 0 / no matching user) or malformed
    /// output. Visible to tests.
    public static func parseSelfLogin(_ data: Data) throws -> String? {
        struct Status: Decodable {
            struct SelfNode: Decodable { let UserID: Int64? }
            struct UserProfile: Decodable { let LoginName: String? }
            let backendState: String?
            let selfNode: SelfNode?
            let users: [String: UserProfile]?
            enum CodingKeys: String, CodingKey {
                case backendState = "BackendState"
                case selfNode = "Self"
                case users = "User"
            }
        }
        let status: Status
        do {
            status = try JSONDecoder().decode(Status.self, from: data)
        } catch {
            throw TailnetIdentityError.invalidResponse
        }
        if let backendState = status.backendState, backendState != "Running" {
            throw TailnetIdentityError.serviceUnavailable
        }
        guard let uid = status.selfNode?.UserID else {
            throw TailnetIdentityError.invalidResponse
        }
        guard uid != 0 else { return nil }
        guard let login = status.users?[String(uid)]?.LoginName, !login.isEmpty else {
            throw TailnetIdentityError.invalidResponse
        }
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
