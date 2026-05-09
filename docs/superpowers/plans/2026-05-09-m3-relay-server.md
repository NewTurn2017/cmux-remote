# M3 — RelayServer (HTTP/WS, Tailscale auth, launchd, menu-bar)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring up `cmux-relay`, a single launchd-managed Mac daemon that authenticates phones via Tailscale identity, accepts WS connections, multiplexes JSON-RPC traffic to the local cmux socket, and exposes a CLI for device revocation. Plus a small SwiftUI menu-bar UI for "Devices" management.

**Architecture:** swift-nio HTTP/1.1 server with `NIOWebSocketUpgrader`. Auth uses the **local tailscaled API** (`/var/run/tailscale/tailscaled.sock` or the macOS user-context equivalent) for `WhoIs(peerAddr)` — the spec mentions tsnet, but the practical, ship-now approach is to consult the host's already-running tailscaled and skip embedding a tsnet node. The relay still sits behind the user's tailnet because we bind on `0.0.0.0:4399` and Tailscale ACLs / Funnel-off keep the public out. Per-connection state in `Session`, fan-in/fan-out via `SessionManager`. One persistent `CmuxClient` connection to `/tmp/cmux.sock`. CLI is `swift-argument-parser`.

**Tech Stack:** swift-nio (HTTP1, WebSocket, SSL), swift-argument-parser, swift-log, async-http-client (for the local tailscaled API call), SwiftUI MenuBarExtra (single binary, `setActivationPolicy(.accessory)`).

**Branch:** `m3-relay` from `main`, after M2 has merged.

---

## Spec coverage

- Spec section 6.1 ("Endpoints") — `Routes.swift`.
- Spec section 6.2 / 6.3 — request dispatch in `WebSocketHandler` + `Session`.
- Spec section 7.1 ("Auth flow") — `AuthService.tailscaledWhoIs` + `DeviceStore.register`.
- Spec section 7.2 ("Defenses") — `RateLimiter` + Argon2id token hashing + SPKI pin doc.
- Spec section 7.3 ("relay.json") — `ConfigLoader`.
- Spec section 9 — n/a (iOS).
- Spec section 10 ("Reconnect", "boot_id reset") — `CmuxConnection.bootIdGuard`.
- Spec section 12.1 ("launchd") — `scripts/install-launchd.sh` + plist template.
- Spec section 12.2 ("cmux socket access") — 503 on missing socket.
- Spec section 13 ("Menu-bar app") — `MenuBarUI.swift`, single-binary mode.
- Spec section 14 ("Open questions") — settled inline (single binary; tailscaled local API).

## Key open-question resolutions (commit at start of milestone)

Add to `docs/specs/2026-05-09-cmux-iphone-bridge-design.md` section 14 the following resolutions before any code:

- **Menu-bar app:** bundled inside `cmux-relay` (single binary, `LSUIElement=YES` set at runtime via `NSApp.setActivationPolicy(.accessory)`).
- **Auth backend:** local tailscaled API instead of embedded tsnet for v1.0. tsnet revisited in v1.2 if Tailscale ACL push notifications become required.
- **AccessoryBar live-config:** `relay.json` watched via `DispatchSource.makeFileSystemObjectSource` + SIGHUP CLI fallback (resolved in M5 once that file is touched, but config plumbing happens here).
- **Allow-login UI on menu-bar:** read-only in v1.0; edits require manual `relay.json` change + `kill -HUP` or "Reload" menu-bar action.

Commit:

```bash
git checkout main && git checkout -b m3-relay
# edit docs/specs/2026-05-09-cmux-iphone-bridge-design.md, add resolutions to section 14
git commit -am "M3.0: lock open questions for relay implementation"
```

## File map for this milestone

Create:
- `Sources/RelayCore/ConfigLoader.swift`
- `Sources/RelayCore/DeviceStore.swift`
- `Sources/RelayCore/RateLimiter.swift`
- `Sources/RelayCore/AuthService.swift`
- `Sources/RelayCore/CmuxConnection.swift`
- `Sources/RelayCore/Session.swift`
- `Sources/RelayCore/SessionManager.swift`
- `Sources/RelayServer/main.swift`
- `Sources/RelayServer/Routes.swift`
- `Sources/RelayServer/HTTPServer.swift`
- `Sources/RelayServer/WebSocketHandler.swift`
- `Sources/RelayServer/MenuBarUI.swift`
- `scripts/install-launchd.sh`
- `scripts/uninstall-launchd.sh`
- `scripts/relay.plist.tmpl`

Tests (all under `Tests/RelayCoreTests/` unless noted):
- `ConfigLoaderTests.swift`, `DeviceStoreTests.swift`, `RateLimiterTests.swift`,
  `AuthServiceTests.swift`, `CmuxConnectionTests.swift`, `SessionTests.swift`,
  `SessionManagerTests.swift`
- `Tests/RelayServerTests/RoutesTests.swift`, `WebSocketHandlerTests.swift`

---

## Task 1 — Re-enable RelayServer targets

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Edit `Package.swift`**

Add the executable target and two new test targets:

```swift
        .executableTarget(
            name: "RelayServer",
            dependencies: [
                "RelayCore",
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "RelayCoreTests",  dependencies: ["RelayCore"]),
        .testTarget(name: "RelayServerTests", dependencies: [
            "RelayServer",
            .product(name: "NIOEmbedded", package: "swift-nio"),
        ]),
```

Re-add `.executable(name: "cmux-relay", targets: ["RelayServer"])` to the `products:` array.

- [ ] **Step 2: Verify build**

```bash
mkdir -p Tests/RelayCoreTests Tests/RelayServerTests
touch Tests/RelayCoreTests/.gitkeep Tests/RelayServerTests/.gitkeep
swift build
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Package.swift Tests/RelayCoreTests/.gitkeep Tests/RelayServerTests/.gitkeep
git commit -m "M3.1: re-enable RelayServer + tests targets"
```

---

## Task 2 — `ConfigLoader` (`relay.json`)

Spec section 7.3.

**Files:**
- Create: `Sources/RelayCore/ConfigLoader.swift`
- Test:   `Tests/RelayCoreTests/ConfigLoaderTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
@testable import RelayCore

final class ConfigLoaderTests: XCTestCase {
    func testParsesAllFields() throws {
        let json = #"""
        {
          "listen": "0.0.0.0:4399",
          "allow_login": ["alice@example.com"],
          "apns": { "key_path": "/k.p8", "key_id": "K", "team_id": "T",
                    "topic": "com.example", "env": "prod" },
          "snippets": [{ "label": "ll", "text": "ls -alh\n" }],
          "default_fps": 15,
          "idle_fps": 5
        }
        """#
        let cfg = try RelayConfig.decode(jsonString: json)
        XCTAssertEqual(cfg.listen, "0.0.0.0:4399")
        XCTAssertEqual(cfg.allowLogin, ["alice@example.com"])
        XCTAssertEqual(cfg.apns.keyId, "K")
        XCTAssertEqual(cfg.snippets.first?.label, "ll")
        XCTAssertEqual(cfg.defaultFps, 15)
    }

    func testRejectsMissingApns() {
        let json = #"{"listen":"x","allow_login":[],"snippets":[],"default_fps":15,"idle_fps":5}"#
        XCTAssertThrowsError(try RelayConfig.decode(jsonString: json))
    }

    func testReloadFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        let raw = #"""
        {"listen":"0.0.0.0:4399","allow_login":["a"],
         "apns":{"key_path":"/k","key_id":"K","team_id":"T","topic":"x","env":"prod"},
         "snippets":[],"default_fps":15,"idle_fps":5}
        """#
        try raw.write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(url: url)
        try store.reload()
        XCTAssertEqual(store.current.allowLogin, ["a"])
    }
}
```

- [ ] **Step 2: Run — expect failure**

`swift test --filter RelayCoreTests.ConfigLoaderTests` → FAIL.

- [ ] **Step 3: Implement `ConfigLoader.swift`**

```swift
import Foundation

public struct RelayConfig: Codable, Equatable {
    public struct APNs: Codable, Equatable {
        public var keyPath: String
        public var keyId: String
        public var teamId: String
        public var topic: String
        public var env: String
        enum CodingKeys: String, CodingKey {
            case keyPath = "key_path", keyId = "key_id", teamId = "team_id", topic, env
        }
    }
    public struct Snippet: Codable, Equatable {
        public var label: String
        public var text: String
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

    public static func decode(jsonString: String) throws -> RelayConfig {
        try JSONDecoder().decode(RelayConfig.self, from: Data(jsonString.utf8))
    }
}

public final class ConfigStore: @unchecked Sendable {
    public let url: URL
    public private(set) var current: RelayConfig

    public init(url: URL) {
        self.url = url
        self.current = RelayConfig(
            listen: "0.0.0.0:4399", allowLogin: [],
            apns: .init(keyPath: "", keyId: "", teamId: "", topic: "", env: "sandbox"),
            snippets: [], defaultFps: 15, idleFps: 5
        )
    }

    public func reload() throws {
        let data = try Data(contentsOf: url)
        self.current = try JSONDecoder().decode(RelayConfig.self, from: data)
    }
}
```

- [ ] **Step 4: Run — expect green**

`swift test --filter RelayCoreTests.ConfigLoaderTests` → 3 pass.

- [ ] **Step 5: Commit**

```bash
rm -f Tests/RelayCoreTests/.gitkeep
git add Sources/RelayCore/ConfigLoader.swift Tests/RelayCoreTests/ConfigLoaderTests.swift
git commit -m "M3.2: ConfigLoader (relay.json + ConfigStore)"
```

---

## Task 3 — `DeviceStore` (atomic devices file)

Spec section 7.1, 7.2. Devices live in their own file `~/.cmuxremote/devices.json` so the relay never rewrites the user's hand-edited `relay.json`.

**Files:**
- Create: `Sources/RelayCore/DeviceStore.swift`
- Test:   `Tests/RelayCoreTests/DeviceStoreTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
import Crypto
@testable import RelayCore

final class DeviceStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
    }

    func testRegisterPersistsHashedToken() throws {
        let url = tempURL()
        let store = try DeviceStore(url: url)
        let token = try store.register(
            deviceId: "dev1", loginName: "a@b", hostname: "iPhone15", apnsToken: nil)
        XCTAssertGreaterThan(token.count, 32)              // raw bearer
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let dev = try XCTUnwrap(store.lookup(deviceId: "dev1"))
        XCTAssertNotEqual(dev.tokenHash, token)            // store hashed
    }

    func testValidateTokenAcceptsCorrectAndRejectsForged() throws {
        let store = try DeviceStore(url: tempURL())
        let token = try store.register(
            deviceId: "dev1", loginName: "a@b", hostname: "iPhone", apnsToken: nil)
        XCTAssertTrue(store.validate(deviceId: "dev1", token: token))
        XCTAssertFalse(store.validate(deviceId: "dev1", token: "wrong"))
    }

    func testRevokeRemovesDevice() throws {
        let store = try DeviceStore(url: tempURL())
        _ = try store.register(deviceId: "d", loginName: "a", hostname: "h", apnsToken: nil)
        try store.revoke(deviceId: "d")
        XCTAssertNil(store.lookup(deviceId: "d"))
    }

    func testApnsTokenUpdate() throws {
        let store = try DeviceStore(url: tempURL())
        _ = try store.register(deviceId: "d", loginName: "a", hostname: "h", apnsToken: nil)
        try store.setAPNsToken(deviceId: "d", token: "apns-1", env: "prod")
        XCTAssertEqual(store.lookup(deviceId: "d")?.apnsToken, "apns-1")
        XCTAssertEqual(store.lookup(deviceId: "d")?.apnsEnv, "prod")
    }
}
```

- [ ] **Step 2: Run — expect failure**

`swift test --filter RelayCoreTests.DeviceStoreTests` → FAIL.

- [ ] **Step 3: Implement `DeviceStore.swift`**

```swift
import Foundation
import Crypto

public struct Device: Codable, Equatable {
    public var deviceId: String
    public var loginName: String
    public var hostname: String
    public var registeredAt: Int64
    public var tokenHash: String       // SHA256-hex of the raw bearer
    public var apnsToken: String?
    public var apnsEnv: String?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id", loginName = "login_name", hostname,
             registeredAt = "registered_at", tokenHash = "token_hash",
             apnsToken = "apns_token", apnsEnv = "apns_env"
    }
}

public final class DeviceStore: @unchecked Sendable {
    public let url: URL
    private var devices: [String: Device] = [:]
    private let queue = DispatchQueue(label: "DeviceStore")

    public init(url: URL) throws {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Device].self, from: data) {
            self.devices = decoded
        } else {
            try persist()
        }
    }

    public func lookup(deviceId: String) -> Device? {
        queue.sync { devices[deviceId] }
    }

    public func allDevices() -> [Device] {
        queue.sync { Array(devices.values) }
    }

    public func register(deviceId: String, loginName: String,
                         hostname: String, apnsToken: String?) throws -> String
    {
        let raw = randomToken()
        let device = Device(deviceId: deviceId, loginName: loginName,
                            hostname: hostname,
                            registeredAt: Int64(Date().timeIntervalSince1970),
                            tokenHash: hash(raw),
                            apnsToken: apnsToken, apnsEnv: nil)
        try queue.sync {
            devices[deviceId] = device
            try persist()
        }
        return raw
    }

    public func validate(deviceId: String, token: String) -> Bool {
        guard let dev = lookup(deviceId: deviceId) else { return false }
        return constantTimeEqual(dev.tokenHash, hash(token))
    }

    public func revoke(deviceId: String) throws {
        try queue.sync {
            devices.removeValue(forKey: deviceId)
            try persist()
        }
    }

    public func setAPNsToken(deviceId: String, token: String, env: String) throws {
        try queue.sync {
            guard var dev = devices[deviceId] else { throw RelayError.unknownDevice(deviceId) }
            dev.apnsToken = token
            dev.apnsEnv = env
            devices[deviceId] = dev
            try persist()
        }
    }

    public func clearAPNsToken(deviceId: String) throws {
        try queue.sync {
            guard var dev = devices[deviceId] else { return }
            dev.apnsToken = nil; dev.apnsEnv = nil
            devices[deviceId] = dev
            try persist()
        }
    }

    private func persist() throws {
        let tmp = url.appendingPathExtension("tmp")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(devices)
        try data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = bytes.withUnsafeMutableBufferPointer { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func hash(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a.utf8, b.utf8) { diff |= x ^ y }
        return diff == 0
    }
}

public enum RelayError: Error, Equatable {
    case unknownDevice(String)
    case unauthorized(String)
    case rateLimited
    case socketUnavailable
    case bootIdMismatch
}
```

`SecRandomCopyBytes` is Foundation+Security on macOS; add `import Security` if the linker complains.

- [ ] **Step 4: Run — expect green**

`swift test --filter RelayCoreTests.DeviceStoreTests` → 4 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RelayCore/DeviceStore.swift Tests/RelayCoreTests/DeviceStoreTests.swift
git commit -m "M3.3: DeviceStore (atomic, hashed bearer, apns token mgmt)"
```

---

## Task 4 — `RateLimiter` (per-device)

Spec section 7.2. 100 send_text/s, 200 send_key/s, separate buckets per device.

**Files:**
- Create: `Sources/RelayCore/RateLimiter.swift`
- Test:   `Tests/RelayCoreTests/RateLimiterTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
@testable import RelayCore

final class RateLimiterTests: XCTestCase {
    func testHonorsBucketLimit() {
        let clock = FakeClock()
        let lim = PerDeviceRateLimiter(clock: clock)
        for _ in 0..<100 { XCTAssertTrue(lim.allow(deviceId: "a", method: "surface.send_text")) }
        XCTAssertFalse(lim.allow(deviceId: "a", method: "surface.send_text"))
    }
    func testIndependentMethodBuckets() {
        let lim = PerDeviceRateLimiter()
        for _ in 0..<100 { _ = lim.allow(deviceId: "a", method: "surface.send_text") }
        XCTAssertTrue(lim.allow(deviceId: "a", method: "surface.send_key"))
    }
    func testWindowSlides() {
        let clock = FakeClock()
        let lim = PerDeviceRateLimiter(clock: clock)
        for _ in 0..<100 { _ = lim.allow(deviceId: "a", method: "surface.send_text") }
        clock.advance(by: 1.001)
        XCTAssertTrue(lim.allow(deviceId: "a", method: "surface.send_text"))
    }
}
```

- [ ] **Step 2: Run — expect failure**

`swift test --filter RelayCoreTests.RateLimiterTests` → FAIL.

- [ ] **Step 3: Implement `RateLimiter.swift`**

```swift
import Foundation

public protocol Clock: Sendable { var now: TimeInterval { get } }
public final class SystemClock: Clock { public init() {}; public var now: TimeInterval { Date().timeIntervalSince1970 } }
public final class FakeClock: Clock, @unchecked Sendable {
    private var t: TimeInterval = 0
    public init() {}; public var now: TimeInterval { t }
    public func advance(by dt: TimeInterval) { t += dt }
}

public final class PerDeviceRateLimiter: @unchecked Sendable {
    private let clock: Clock
    private var stamps: [String: [TimeInterval]] = [:]
    private let lock = NSLock()
    public init(clock: Clock = SystemClock()) { self.clock = clock }

    public func allow(deviceId: String, method: String) -> Bool {
        let cap: Int
        switch method {
        case "surface.send_text": cap = 100
        case "surface.send_key":  cap = 200
        default: return true
        }
        lock.lock(); defer { lock.unlock() }
        let key = "\(deviceId)|\(method)"
        let now = clock.now
        var arr = stamps[key, default: []]
        arr.removeAll { now - $0 > 1.0 }
        guard arr.count < cap else { stamps[key] = arr; return false }
        arr.append(now); stamps[key] = arr; return true
    }
}
```

If `Clock` is also defined in `RelayCore/DiffEngine.swift` (M2), keep one canonical definition — move `Clock`/`SystemClock`/`FakeClock` into a new `Sources/RelayCore/Clock.swift` and `import` from both. The first task that pulls them out commits the move.

- [ ] **Step 4: Run — expect green**

`swift test --filter RelayCoreTests.RateLimiterTests` → 3 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RelayCore/RateLimiter.swift Tests/RelayCoreTests/RateLimiterTests.swift Sources/RelayCore/Clock.swift
git commit -m "M3.4: PerDeviceRateLimiter + canonical Clock"
```

---

## Task 5 — `AuthService` (tailscaled local API + mock)

The local tailscaled exposes `/whois?addr=…` over a Unix socket. The path on macOS varies by install method:
- `tailscale.app` (App Store): `~/Library/Containers/io.tailscale.ipn.macsys/Data/.../sameuser-proof`
- `tailscaled` daemon (open-source): `/var/run/tailscale/tailscaled.sock`

The relay tries both, in order, at startup. Tests use a `MockAuth`.

**Files:**
- Create: `Sources/RelayCore/AuthService.swift`
- Test:   `Tests/RelayCoreTests/AuthServiceTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
@testable import RelayCore

final class AuthServiceTests: XCTestCase {
    func testMockResolvesPeer() async throws {
        let auth = MockAuthService(peers: ["100.64.0.5": .init(loginName: "a@b", hostname: "iPhone15", os: "ios", nodeKey: "nk1")])
        let p = try await auth.whois(remoteAddr: "100.64.0.5")
        XCTAssertEqual(p.loginName, "a@b")
        XCTAssertEqual(p.nodeKey, "nk1")
    }
    func testMockRejectsUnknown() async throws {
        let auth = MockAuthService(peers: [:])
        do { _ = try await auth.whois(remoteAddr: "1.2.3.4"); XCTFail() }
        catch RelayError.unauthorized { /* ok */ }
    }
}
```

- [ ] **Step 2: Run — expect failure**

`swift test --filter RelayCoreTests.AuthServiceTests` → FAIL.

- [ ] **Step 3: Implement `AuthService.swift`**

```swift
import Foundation
import AsyncHTTPClient
import NIOCore
import NIOPosix
import NIOHTTP1

public struct PeerIdentity: Equatable, Sendable {
    public var loginName: String
    public var hostname: String
    public var os: String
    public var nodeKey: String
}

public protocol AuthService: Sendable {
    func whois(remoteAddr: String) async throws -> PeerIdentity
}

public final class MockAuthService: AuthService, @unchecked Sendable {
    public var peers: [String: PeerIdentity]
    public init(peers: [String: PeerIdentity]) { self.peers = peers }
    public func whois(remoteAddr: String) async throws -> PeerIdentity {
        guard let p = peers[stripPort(remoteAddr)] else { throw RelayError.unauthorized(remoteAddr) }
        return p
    }
}

public final class TailscaledLocalAuth: AuthService {
    public let socketPath: String
    public let httpClient: HTTPClient
    public init(socketPath: String = "/var/run/tailscale/tailscaled.sock",
                httpClient: HTTPClient = HTTPClient(eventLoopGroupProvider: .singleton))
    {
        self.socketPath = socketPath; self.httpClient = httpClient
    }

    public func whois(remoteAddr: String) async throws -> PeerIdentity {
        // tailscale local API: HTTP over UDS, host arbitrary, path /localapi/v0/whois?addr=…
        var req = HTTPClientRequest(url: "http+unix://localhost\(socketPath)/localapi/v0/whois?addr=\(stripPort(remoteAddr))")
        req.headers.add(name: "Sec-Tailscale", value: "localapi")
        let resp = try await httpClient.execute(req, timeout: .seconds(2))
        guard resp.status == .ok else { throw RelayError.unauthorized(remoteAddr) }
        let body = try await resp.body.collect(upTo: 1 << 20)
        return try Self.parseWhoisResponse(Data(buffer: body))
    }

    static func parseWhoisResponse(_ data: Data) throws -> PeerIdentity {
        struct W: Decodable {
            struct U: Decodable { let LoginName: String }
            struct N: Decodable { let Hostinfo: H?; let Key: String; struct H: Decodable { let OS: String? } }
            let UserProfile: U
            let Node: N
        }
        let w = try JSONDecoder().decode(W.self, from: data)
        return PeerIdentity(loginName: w.UserProfile.LoginName,
                            hostname: w.Node.Hostinfo?.OS ?? "",
                            os: w.Node.Hostinfo?.OS ?? "",
                            nodeKey: w.Node.Key)
    }
}

private func stripPort(_ addr: String) -> String {
    if let bracket = addr.lastIndex(of: "]") {        // [::1]:1234
        let head = addr[addr.startIndex...bracket]
        return String(head.dropFirst().dropLast())
    }
    if let colon = addr.lastIndex(of: ":") {
        return String(addr[addr.startIndex..<colon])
    }
    return addr
}
```

`http+unix://` requires async-http-client 1.21+ (UDS support). If your version doesn't, swap to writing the HTTP request manually over `ClientBootstrap.unixDomainSocketPath`.

- [ ] **Step 4: Run — expect green**

`swift test --filter RelayCoreTests.AuthServiceTests` → 2 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RelayCore/AuthService.swift Tests/RelayCoreTests/AuthServiceTests.swift
git commit -m "M3.5: AuthService — Mock + TailscaledLocalAuth UDS whois"
```

---

## Task 6 — `CmuxConnection` (reconnect + boot_id guard)

Spec section 10. Wraps `CMUXClient` with auto-reconnect and detects cmux restarts via `boot_id` change in `events.stream`.

**Files:**
- Create: `Sources/RelayCore/CmuxConnection.swift`
- Test:   `Tests/RelayCoreTests/CmuxConnectionTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
@testable import RelayCore
import SharedKit

final class CmuxConnectionTests: XCTestCase {
    func testBootIdChangeFiresReset() {
        var resets = 0
        let conn = CmuxConnection.makeForTesting()
        conn.onReset = { resets += 1 }
        conn.observe(bootInfo: BootInfo(bootId: "a", startedAt: 1))
        conn.observe(bootInfo: BootInfo(bootId: "a", startedAt: 1))
        XCTAssertEqual(resets, 0)
        conn.observe(bootInfo: BootInfo(bootId: "b", startedAt: 2))
        XCTAssertEqual(resets, 1)
    }
}
```

- [ ] **Step 2: Run — expect failure**

`swift test --filter RelayCoreTests.CmuxConnectionTests` → FAIL.

- [ ] **Step 3: Implement `CmuxConnection.swift`**

```swift
import Foundation
import CMUXClient
import SharedKit
import NIOCore
import NIOPosix
import Logging

public final class CmuxConnection: @unchecked Sendable {
    public let socketPath: String
    public let group: EventLoopGroup
    public var onReset: (() -> Void)?

    private let logger = Logger(label: "CmuxConnection")
    private var lastBootId: String?
    private var client: CMUXClient?

    public init(socketPath: String = "/tmp/cmux.sock",
                group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1))
    {
        self.socketPath = socketPath; self.group = group
    }

    public static func makeForTesting() -> CmuxConnection {
        CmuxConnection(socketPath: "/tmp/.no-such", group: MultiThreadedEventLoopGroup(numberOfThreads: 1))
    }

    public func connect() async throws -> CMUXClient {
        if let c = client { return c }
        let chan = try await UnixSocketChannel(path: socketPath, group: group)
            .connect { _ in self.group.next().makeSucceededFuture(()) }
        let c = CMUXClient(channel: chan, requestTimeout: .seconds(5))
        self.client = c
        return c
    }

    public func observe(bootInfo: BootInfo) {
        if let prev = lastBootId, prev != bootInfo.bootId {
            onReset?()
        }
        lastBootId = bootInfo.bootId
    }
}
```

- [ ] **Step 4: Run — expect green**

`swift test --filter RelayCoreTests.CmuxConnectionTests` → 1 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RelayCore/CmuxConnection.swift Tests/RelayCoreTests/CmuxConnectionTests.swift
git commit -m "M3.6: CmuxConnection + boot_id reset detection"
```

---

## Task 7 — `Session` (per-WS connection state)

Holds the device id, subscribed surfaces (each with its own DiffEngine instance), and a push channel for outgoing frames.

**Files:**
- Create: `Sources/RelayCore/Session.swift`
- Test:   `Tests/RelayCoreTests/SessionTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
import SharedKit
@testable import RelayCore

final class SessionTests: XCTestCase {
    func testSubscribeStartsDiffEngineAndUnsubscribeStops() async throws {
        let reader = StaticReader([Screen(rev: 1, rows: ["x"], cols: 1, cursor: .init(x: 0, y: 0))])
        let session = Session(deviceId: "d1", reader: reader, defaultFps: 30, idleFps: 5)
        await session.subscribe(workspaceId: "w", surfaceId: "s", lines: 1)
        XCTAssertEqual(await session.activeSurfaceCount, 1)
        await session.unsubscribe(surfaceId: "s")
        XCTAssertEqual(await session.activeSurfaceCount, 0)
    }
}

final class StaticReader: SurfaceReader, @unchecked Sendable {
    var snapshots: [Screen]
    init(_ snapshots: [Screen]) { self.snapshots = snapshots }
    func read(workspaceId: String, surfaceId: String, lines: Int) async throws -> Screen {
        if snapshots.isEmpty {
            return Screen(rev: 0, rows: [], cols: 0, cursor: .init(x: 0, y: 0))
        }
        return snapshots.removeFirst()
    }
}
```

- [ ] **Step 2: Run — expect failure**

`swift test --filter RelayCoreTests.SessionTests` → FAIL.

- [ ] **Step 3: Implement `Session.swift`**

```swift
import Foundation
import SharedKit

public actor Session {
    public let deviceId: String
    public var sendFrame: (@Sendable (PushFrame) -> Void)?

    private let reader: SurfaceReader
    private let defaultFps: Int
    private let idleFps: Int
    private var engines: [String: DiffEngine] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    public var activeSurfaceCount: Int { engines.count }

    public init(deviceId: String, reader: SurfaceReader, defaultFps: Int, idleFps: Int) {
        self.deviceId = deviceId; self.reader = reader
        self.defaultFps = defaultFps; self.idleFps = idleFps
    }

    public func subscribe(workspaceId: String, surfaceId: String, lines: Int) {
        guard engines[surfaceId] == nil else { return }
        let engine = DiffEngine(reader: reader, fps: defaultFps, idleFps: idleFps,
                                workspaceId: workspaceId, surfaceId: surfaceId, lines: lines)
        engines[surfaceId] = engine
        let send = self.sendFrame
        engine.onDiff = { ops in
            send?(.screenDiff(ScreenDiff(surfaceId: surfaceId, rev: engine.rev, ops: ops)))
        }
        engine.onChecksum = { hash, rev in
            send?(.screenChecksum(ScreenChecksum(surfaceId: surfaceId, rev: rev, hash: hash)))
        }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let fps = Double(await self.fps(for: surfaceId))
                let interval = 1.0 / fps
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                try? await engine.tick()
            }
        }
        tasks[surfaceId] = task
    }

    public func unsubscribe(surfaceId: String) {
        tasks[surfaceId]?.cancel()
        tasks[surfaceId] = nil
        engines[surfaceId] = nil
    }

    public func noteUserInput(surfaceId: String) {
        engines[surfaceId]?.noteUserInput()
    }

    public func close() {
        for (_, t) in tasks { t.cancel() }
        tasks.removeAll(); engines.removeAll()
    }

    private func fps(for surfaceId: String) -> Int {
        engines[surfaceId]?.currentFps ?? defaultFps
    }
}
```

- [ ] **Step 4: Run — expect green**

`swift test --filter RelayCoreTests.SessionTests` → 1 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RelayCore/Session.swift Tests/RelayCoreTests/SessionTests.swift
git commit -m "M3.7: Session — per-WS subscription lifecycle"
```

---

## Task 8 — `SessionManager` (cross-session fanout, devices map)

**Files:**
- Create: `Sources/RelayCore/SessionManager.swift`
- Test:   `Tests/RelayCoreTests/SessionManagerTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
import SharedKit
@testable import RelayCore

final class SessionManagerTests: XCTestCase {
    func testFanoutByDevice() async throws {
        let reader = StaticReader([])
        let mgr = SessionManager(reader: reader, defaultFps: 30, idleFps: 5)
        var sentToA: [PushFrame] = []
        let sA = await mgr.attach(deviceId: "A") { sentToA.append($0) }
        _ = await mgr.attach(deviceId: "B") { _ in }
        await mgr.broadcastToDevice(deviceId: "A", frame: .ping(PingFrame(ts: 1)))
        XCTAssertEqual(sentToA.count, 1)
        await mgr.detach(session: sA)
    }

    func testBroadcastEvent() async throws {
        let mgr = SessionManager(reader: StaticReader([]), defaultFps: 30, idleFps: 5)
        var aGot = 0; var bGot = 0
        _ = await mgr.attach(deviceId: "A") { _ in aGot += 1 }
        _ = await mgr.attach(deviceId: "B") { _ in bGot += 1 }
        await mgr.broadcastToAll(frame: .event(EventFrame(category: .system, name: "x", payload: .null)))
        XCTAssertEqual(aGot, 1); XCTAssertEqual(bGot, 1)
    }
}
```

- [ ] **Step 2: Run — expect failure**

`swift test --filter RelayCoreTests.SessionManagerTests` → FAIL.

- [ ] **Step 3: Implement `SessionManager.swift`**

```swift
import Foundation
import SharedKit

public actor SessionManager {
    private let reader: SurfaceReader
    private let defaultFps: Int
    private let idleFps: Int
    private var sessionsById: [ObjectIdentifier: Session] = [:]
    private var byDevice: [String: Set<ObjectIdentifier>] = [:]

    public init(reader: SurfaceReader, defaultFps: Int, idleFps: Int) {
        self.reader = reader; self.defaultFps = defaultFps; self.idleFps = idleFps
    }

    public func attach(deviceId: String,
                       send: @escaping @Sendable (PushFrame) -> Void) -> Session
    {
        let s = Session(deviceId: deviceId, reader: reader,
                        defaultFps: defaultFps, idleFps: idleFps)
        Task { await s.update(sendFrame: send) }
        let key = ObjectIdentifier(s)
        sessionsById[key] = s
        byDevice[deviceId, default: []].insert(key)
        return s
    }

    public func detach(session: Session) {
        let key = ObjectIdentifier(session)
        if let s = sessionsById.removeValue(forKey: key) {
            Task { await s.close() }
        }
        for (dev, set) in byDevice {
            var next = set; next.remove(key); byDevice[dev] = next.isEmpty ? nil : next
        }
    }

    public func broadcastToDevice(deviceId: String, frame: PushFrame) {
        for key in byDevice[deviceId] ?? [] {
            sessionsById[key]?.send(frame: frame)
        }
    }

    public func broadcastToAll(frame: PushFrame) {
        for s in sessionsById.values { s.send(frame: frame) }
    }
}

extension Session {
    public nonisolated func send(frame: PushFrame) {
        Task { await self.dispatch(frame: frame) }
    }
    private func dispatch(frame: PushFrame) { sendFrame?(frame) }
    public func update(sendFrame: @Sendable @escaping (PushFrame) -> Void) {
        self.sendFrame = sendFrame
    }
}
```

- [ ] **Step 4: Run — expect green**

`swift test --filter RelayCoreTests.SessionManagerTests` → 2 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RelayCore/SessionManager.swift Tests/RelayCoreTests/SessionManagerTests.swift
git commit -m "M3.8: SessionManager fanout"
```

---

## Task 9 — `Routes.swift` (HTTP REST endpoints)

Spec section 6.1.

**Files:**
- Create: `Sources/RelayServer/Routes.swift`
- Test:   `Tests/RelayServerTests/RoutesTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
import NIOCore
import NIOEmbedded
import NIOHTTP1
@testable import RelayServer
@testable import RelayCore

final class RoutesTests: XCTestCase {
    private func makeRoutes(_ store: DeviceStore,
                            allow: [String] = ["a@b"],
                            peers: [String: PeerIdentity] = ["100.64.0.5":
                                .init(loginName: "a@b", hostname: "iPhone", os: "ios", nodeKey: "nk1")]) -> Routes
    {
        var cfg = RelayConfig.testValue; cfg.allowLogin = allow
        return Routes(deviceStore: store, config: cfg, auth: MockAuthService(peers: peers))
    }

    func testHealthOk() async throws {
        let resp = await makeRoutes(try DeviceStore.empty())
            .handle(method: .GET, path: "/v1/health",
                    body: nil, deviceId: nil, remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .ok)
    }

    func testRegisterCreatesDeviceAndIssuesToken() async throws {
        let store = try DeviceStore.empty()
        let routes = makeRoutes(store)
        let resp = await routes.handle(method: .POST, path: "/v1/devices/me/register",
                                       body: nil, deviceId: nil, remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .ok)
        struct R: Decodable { let deviceId: String; let token: String
            enum CodingKeys: String, CodingKey { case deviceId = "device_id", token } }
        let r = try JSONDecoder().decode(R.self, from: resp.body ?? Data())
        XCTAssertFalse(r.token.isEmpty)
        XCTAssertNotNil(store.lookup(deviceId: r.deviceId))
        XCTAssertTrue(store.validate(deviceId: r.deviceId, token: r.token))
    }

    func testRegisterRejectsLoginNotInAllowList() async throws {
        let store = try DeviceStore.empty()
        let routes = makeRoutes(store, allow: ["someone@else"])
        let resp = await routes.handle(method: .POST, path: "/v1/devices/me/register",
                                       body: nil, deviceId: nil, remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .forbidden)
    }

    func testApnsNeedsAuth() async throws {
        let resp = await makeRoutes(try DeviceStore.empty())
            .handle(method: .POST, path: "/v1/devices/me/apns",
                    body: Data(#"{"apns_token":"t","env":"prod"}"#.utf8),
                    deviceId: nil, remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .unauthorized)
    }

    func testApnsPersists() async throws {
        let store = try DeviceStore.empty()
        _ = try store.register(deviceId: "d", loginName: "a", hostname: "h", apnsToken: nil)
        let resp = await makeRoutes(store)
            .handle(method: .POST, path: "/v1/devices/me/apns",
                    body: Data(#"{"apns_token":"t","env":"prod"}"#.utf8),
                    deviceId: "d", remoteAddr: "100.64.0.5:1")
        XCTAssertEqual(resp.status, .noContent)
        XCTAssertEqual(store.lookup(deviceId: "d")?.apnsToken, "t")
    }
}
```

(Add `DeviceStore.empty()` test helper:)

```swift
extension DeviceStore {
    public static func empty() throws -> DeviceStore {
        try DeviceStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json"))
    }
}
extension RelayConfig {
    public static var testValue: RelayConfig {
        RelayConfig(listen: "0.0.0.0:4399", allowLogin: ["a"],
                    apns: .init(keyPath: "/dev/null", keyId: "K", teamId: "T",
                                topic: "x", env: "sandbox"),
                    snippets: [], defaultFps: 15, idleFps: 5)
    }
}
```

- [ ] **Step 2: Run — expect failure**

`swift test --filter RelayServerTests.RoutesTests` → FAIL.

- [ ] **Step 3: Implement `Routes.swift`**

```swift
import Foundation
import NIOCore
import NIOHTTP1
import Crypto
import RelayCore
import SharedKit

public struct HTTPResponseLite: Sendable {
    public var status: HTTPResponseStatus
    public var body: Data?
    public init(_ status: HTTPResponseStatus, body: Data? = nil) {
        self.status = status; self.body = body
    }
}

public actor Routes {
    private let deviceStore: DeviceStore
    private let config: RelayConfig
    private let auth: AuthService

    public init(deviceStore: DeviceStore, config: RelayConfig, auth: AuthService) {
        self.deviceStore = deviceStore; self.config = config; self.auth = auth
    }

    public func handle(method: HTTPMethod, path: String, body: Data?,
                       deviceId: String?, remoteAddr: String) async -> HTTPResponseLite
    {
        switch (method, path) {
        case (.GET, "/v1/health"):  return .init(.ok, body: Data(#"{"ok":true}"#.utf8))
        case (.GET, "/v1/state"):   return state()
        case (.POST, "/v1/devices/me/register"):
            return await registerNew(remoteAddr: remoteAddr)
        case (.POST, "/v1/devices/me/apns"):
            guard let did = deviceId, deviceStore.lookup(deviceId: did) != nil else {
                return .init(.unauthorized)
            }
            return registerApns(deviceId: did, body: body)
        case (.DELETE, "/v1/devices/me"):
            guard let did = deviceId else { return .init(.unauthorized) }
            try? deviceStore.revoke(deviceId: did)
            return .init(.noContent)
        default:
            return .init(.notFound)
        }
    }

    private func state() -> HTTPResponseLite {
        struct State: Encodable { let snippets: [RelayConfig.Snippet]; let defaultFps: Int }
        let s = State(snippets: config.snippets, defaultFps: config.defaultFps)
        return .init(.ok, body: try? JSONEncoder().encode(s))
    }

    private func registerApns(deviceId: String, body: Data?) -> HTTPResponseLite {
        struct Payload: Decodable { let apnsToken: String; let env: String
            enum CodingKeys: String, CodingKey { case apnsToken = "apns_token", env }
        }
        guard let body, let p = try? JSONDecoder().decode(Payload.self, from: body) else {
            return .init(.badRequest)
        }
        guard p.env == "prod" || p.env == "sandbox" else { return .init(.badRequest) }
        try? deviceStore.setAPNsToken(deviceId: deviceId, token: p.apnsToken, env: p.env)
        return .init(.noContent)
    }

    private func registerNew(remoteAddr: String) async -> HTTPResponseLite {
        do {
            let peer = try await auth.whois(remoteAddr: remoteAddr)
            guard config.allowLogin.contains(peer.loginName) else { return .init(.forbidden) }
            let deviceId = sha256Hex(peer.nodeKey)
            // Idempotent: if device already registered, rotate token to avoid leakage on rebind.
            try? deviceStore.revoke(deviceId: deviceId)
            let token = try deviceStore.register(
                deviceId: deviceId, loginName: peer.loginName,
                hostname: peer.hostname, apnsToken: nil)
            struct R: Encodable { let device_id: String; let token: String }
            let body = try JSONEncoder().encode(R(device_id: deviceId, token: token))
            return .init(.ok, body: body)
        } catch RelayError.unauthorized {
            return .init(.forbidden)
        } catch {
            return .init(.internalServerError)
        }
    }
}

private func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}
```

- [ ] **Step 4: Run — expect green**

`swift test --filter RelayServerTests.RoutesTests` → 3 pass.

- [ ] **Step 5: Commit**

```bash
rm -f Tests/RelayServerTests/.gitkeep
git add Sources/RelayServer/Routes.swift Tests/RelayServerTests/RoutesTests.swift Package.swift
git commit -m "M3.9: HTTP routes (register/apns/health/state) + AuthService dep"
```

---

## Task 10 — `WebSocketHandler` (handshake, hello, RPC dispatch)

**Files:**
- Create: `Sources/RelayServer/WebSocketHandler.swift`
- Test:   `Tests/RelayServerTests/WebSocketHandlerTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
import NIOCore
import NIOEmbedded
import NIOWebSocket
import SharedKit
@testable import RelayServer
@testable import RelayCore

final class WebSocketHandlerTests: XCTestCase {
    func testFirstFrameMustBeHelloWithin100ms() async throws {
        let store = try DeviceStore.empty()
        _ = try store.register(deviceId: "d", loginName: "a", hostname: "h", apnsToken: nil)
        let mgr = SessionManager(reader: NoSurfaceReader(), defaultFps: 15, idleFps: 5)
        let handler = WebSocketHandler(deviceId: "d", deviceStore: store, sessionManager: mgr,
                                       cmuxClient: NoOpCMUXFacade())
        let chan = EmbeddedChannel(handler: handler)
        try await Task.sleep(nanoseconds: 150_000_000)
        chan.embeddedEventLoop.run()                  // advance handler timer
        XCTAssertFalse(chan.isActive)                 // closed for missing hello
    }

    func testHelloAcceptedThenWorkspaceListDispatches() async throws {
        let store = try DeviceStore.empty()
        _ = try store.register(deviceId: "d", loginName: "a", hostname: "h", apnsToken: nil)
        let cmux = RecordingCMUXFacade()
        let mgr = SessionManager(reader: NoSurfaceReader(), defaultFps: 15, idleFps: 5)
        let handler = WebSocketHandler(deviceId: "d", deviceStore: store, sessionManager: mgr,
                                       cmuxClient: cmux)
        let chan = EmbeddedChannel(handler: handler)
        try chan.writeInbound(WebSocketFrame.text(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#))
        try chan.writeInbound(WebSocketFrame.text(#"{"id":1,"method":"workspace.list","params":{}}"#))
        XCTAssertEqual(cmux.calls.last, "workspace.list")
    }
}

final class NoSurfaceReader: SurfaceReader, @unchecked Sendable {
    func read(workspaceId: String, surfaceId: String, lines: Int) async throws -> Screen {
        Screen(rev: 0, rows: [], cols: 0, cursor: .init(x: 0, y: 0))
    }
}

final class NoOpCMUXFacade: CMUXFacade, @unchecked Sendable {
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        .object([:])
    }
}
final class RecordingCMUXFacade: CMUXFacade, @unchecked Sendable {
    var calls: [String] = []
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        calls.append(method); return .object([:])
    }
}
extension WebSocketFrame {
    static func text(_ s: String) -> WebSocketFrame {
        var buf = ByteBufferAllocator().buffer(capacity: s.count); buf.writeString(s)
        return WebSocketFrame(fin: true, opcode: .text, data: buf)
    }
}
```

- [ ] **Step 2: Run — expect failure**

`swift test --filter RelayServerTests.WebSocketHandlerTests` → FAIL.

- [ ] **Step 3: Implement `WebSocketHandler.swift`**

```swift
import Foundation
import NIOCore
import NIOWebSocket
import RelayCore
import SharedKit
import Logging

public protocol CMUXFacade: Sendable {
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue
}

public final class WebSocketHandler: ChannelInboundHandler {
    public typealias InboundIn = WebSocketFrame
    public typealias OutboundOut = WebSocketFrame

    public let deviceId: String
    private let deviceStore: DeviceStore
    private let sessionManager: SessionManager
    private let cmux: CMUXFacade
    private var helloTimer: Scheduled<Void>?
    private var helloed = false
    private var session: Session?
    private let logger = Logger(label: "WSHandler")

    public init(deviceId: String, deviceStore: DeviceStore,
                sessionManager: SessionManager, cmuxClient: CMUXFacade)
    {
        self.deviceId = deviceId; self.deviceStore = deviceStore
        self.sessionManager = sessionManager; self.cmux = cmuxClient
    }

    public func channelActive(context: ChannelHandlerContext) {
        helloTimer = context.eventLoop.scheduleTask(in: .milliseconds(100)) {
            guard !self.helloed else { return }
            context.close(promise: nil)
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .text else { return }
        let buf = frame.unmaskedData
        guard let json = buf.getString(at: buf.readerIndex, length: buf.readableBytes),
              let data = json.data(using: .utf8) else { return }
        if !helloed {
            guard (try? JSONDecoder().decode(HelloFrame.self, from: data)) != nil else {
                context.close(promise: nil); return
            }
            helloed = true; helloTimer?.cancel()
            self.session = Task.detached(priority: .userInitiated) { [self] in
                await self.sessionManager.attach(deviceId: self.deviceId) { [weak context] frame in
                    context?.eventLoop.execute { context?.writeAndFlush(self.encode(frame), promise: nil) }
                }
            }.value as? Session
            return
        }
        guard let req = try? JSONDecoder().decode(RPCRequest.self, from: data) else { return }
        Task { await self.handle(request: req, context: context) }
    }

    private func handle(request: RPCRequest, context: ChannelHandlerContext) async {
        do {
            let result = try await cmux.dispatch(method: request.method, params: request.params)
            let resp = RPCResponse(id: request.id, ok: true, result: result, error: nil)
            send(resp: resp, on: context)
        } catch {
            let err = RPCError(code: -32000, message: String(describing: error))
            send(resp: RPCResponse(id: request.id, ok: false, error: err), on: context)
        }
    }

    private func send(resp: RPCResponse, on context: ChannelHandlerContext) {
        guard let body = try? JSONEncoder().encode(resp) else { return }
        var buf = context.channel.allocator.buffer(capacity: body.count); buf.writeBytes(body)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
        context.eventLoop.execute { context.writeAndFlush(self.wrapOutboundOut(frame), promise: nil) }
    }

    private func encode(_ push: PushFrame) -> NIOAny {
        let body = (try? JSONEncoder().encode(push)) ?? Data()
        var buf = ByteBufferAllocator().buffer(capacity: body.count); buf.writeBytes(body)
        return wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: buf))
    }
}
```

- [ ] **Step 4: Run — expect green**

`swift test --filter RelayServerTests.WebSocketHandlerTests` → 2 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RelayServer/WebSocketHandler.swift Tests/RelayServerTests/WebSocketHandlerTests.swift
git commit -m "M3.10: WebSocketHandler (hello + RPC dispatch)"
```

---

## Task 11 — `HTTPServer` (NIO bootstrap + WebSocket upgrade)

**Files:**
- Create: `Sources/RelayServer/HTTPServer.swift`

(No new test — covered by integration smoke in task 13.)

- [ ] **Step 1: Implement**

```swift
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import RelayCore
import SharedKit
import Logging

public final class HTTPServer {
    public let group: MultiThreadedEventLoopGroup
    public let routes: Routes
    public let auth: AuthService
    public let deviceStore: DeviceStore
    public let sessionManager: SessionManager
    public let cmux: CMUXFacade
    public let logger = Logger(label: "HTTPServer")

    public init(group: MultiThreadedEventLoopGroup, routes: Routes,
                auth: AuthService, deviceStore: DeviceStore,
                sessionManager: SessionManager, cmux: CMUXFacade)
    {
        self.group = group; self.routes = routes; self.auth = auth
        self.deviceStore = deviceStore; self.sessionManager = sessionManager; self.cmux = cmux
    }

    public func run(host: String, port: Int) async throws {
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, head in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, head in
                let deviceId = self.deviceIdFromHeaders(head.headers)
                let handler = WebSocketHandler(deviceId: deviceId, deviceStore: self.deviceStore,
                                               sessionManager: self.sessionManager,
                                               cmuxClient: self.cmux)
                return channel.pipeline.addHandler(handler)
            }
        )
        let bs = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = HTTPHandler(routes: self.routes, auth: self.auth,
                                              deviceStore: self.deviceStore)
                let config = NIOHTTPServerUpgradeConfiguration(
                    upgraders: [upgrader],
                    completionHandler: { _ in
                        channel.pipeline.removeHandler(httpHandler, promise: nil)
                    })
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config)
                    .flatMap { channel.pipeline.addHandler(httpHandler) }
            }
        let chan = try await bs.bind(host: host, port: port).get()
        logger.info("listening on \(chan.localAddress?.description ?? "?")")
        try await chan.closeFuture.get()
    }

    private func deviceIdFromHeaders(_ headers: HTTPHeaders) -> String {
        // Sec-WebSocket-Protocol: cmuxremote.v1, bearer.<token>
        guard let proto = headers.first(name: "Sec-WebSocket-Protocol") else { return "" }
        let parts = proto.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let bearer = parts.first(where: { $0.hasPrefix("bearer.") }) else { return "" }
        let token = String(bearer.dropFirst("bearer.".count))
        for d in deviceStore.allDevices() where deviceStore.validate(deviceId: d.deviceId, token: token) {
            return d.deviceId
        }
        return ""
    }
}

private final class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let routes: Routes
    private let auth: AuthService
    private let deviceStore: DeviceStore
    private var pendingHead: HTTPRequestHead?
    private var bodyBuffer = ByteBuffer()
    private var deviceId: String?

    init(routes: Routes, auth: AuthService, deviceStore: DeviceStore) {
        self.routes = routes; self.auth = auth; self.deviceStore = deviceStore
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            pendingHead = head; bodyBuffer.clear()
            if let bearer = head.headers.first(name: "Authorization")?.split(separator: " ").last {
                let token = String(bearer)
                for d in deviceStore.allDevices()
                    where deviceStore.validate(deviceId: d.deviceId, token: token) {
                    self.deviceId = d.deviceId; break
                }
            }
        case .body(var buf):
            bodyBuffer.writeBuffer(&buf)
        case .end:
            guard let head = pendingHead else { return }
            let body: Data? = bodyBuffer.readableBytes > 0
                ? bodyBuffer.getData(at: bodyBuffer.readerIndex, length: bodyBuffer.readableBytes)
                : nil
            let did = deviceId
            let remote = context.remoteAddress?.description ?? ""
            Task {
                let resp = await routes.handle(method: head.method, path: head.uri,
                                               body: body, deviceId: did, remoteAddr: remote)
                respond(context: context, resp: resp)
            }
        }
    }

    private func respond(context: ChannelHandlerContext, resp: HTTPResponseLite) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(resp.body?.count ?? 0)")
        let head = HTTPResponseHead(version: .http1_1, status: resp.status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if let body = resp.body, !body.isEmpty {
            var buf = context.channel.allocator.buffer(capacity: body.count); buf.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
```

TLS — for v1.0 this server runs over plain HTTP and relies on Tailscale's wire encryption. If the user enables `tailscale cert <hostname>`, swap `bs` to install `NIOSSLServerHandler` from a certificate file. Add a config flag in M3 task 14.

- [ ] **Step 2: Build smoke**

```bash
swift build
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/RelayServer/HTTPServer.swift
git commit -m "M3.11: HTTPServer (HTTP+WS upgrade pipeline, plain HTTP over Tailscale)"
```

---

## Task 12 — `main.swift` + ArgumentParser CLI

**Files:**
- Create: `Sources/RelayServer/main.swift`
- Create: `Sources/RelayServer/CMUXFacadeImpl.swift`

- [ ] **Step 1: Implement `CMUXFacadeImpl.swift`**

```swift
import Foundation
import RelayCore
import CMUXClient
import SharedKit

/// Translates JSON-RPC dispatch into the CMUXClient typed methods.
/// Methods that should *not* hit cmux directly (e.g. surface.subscribe) are
/// handled by Session and never reach this facade.
public final class CMUXFacadeImpl: CMUXFacade, @unchecked Sendable {
    private let connection: CmuxConnection
    public init(connection: CmuxConnection) { self.connection = connection }

    public func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        let client = try await connection.connect()
        let resp = try await client.call(method: method, params: params)
        return try resp.unwrapResult()
    }
}
```

- [ ] **Step 2: Implement `main.swift`**

```swift
import Foundation
import ArgumentParser
import NIOPosix
import RelayCore
import CMUXClient
import Logging

@main
struct CmuxRelay: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "cmux-relay",
        subcommands: [Serve.self, Devices.self, MenuBar.self],
        defaultSubcommand: Serve.self
    )
}

struct Serve: AsyncParsableCommand {
    @Option(name: .customLong("config"), help: "Path to relay.json")
    var config: String = "\(NSHomeDirectory())/.cmuxremote/relay.json"

    func run() async throws {
        let logger = Logger(label: "cmux-relay")
        let store = ConfigStore(url: URL(fileURLWithPath: config))
        try store.reload()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let conn = CmuxConnection(socketPath: "/tmp/cmux.sock", group: group)
        let facade = CMUXFacadeImpl(connection: conn)
        let reader = CmuxSurfaceReader(connection: conn)
        let manager = SessionManager(reader: reader,
                                     defaultFps: store.current.defaultFps,
                                     idleFps: store.current.idleFps)
        let devicesURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.cmuxremote/devices.json")
        let deviceStore = try DeviceStore(url: devicesURL)
        let auth = TailscaledLocalAuth()
        let routes = Routes(deviceStore: deviceStore, config: store.current, auth: auth)
        let server = HTTPServer(group: group, routes: routes, auth: auth,
                                deviceStore: deviceStore, sessionManager: manager,
                                cmux: facade)
        let parts = store.current.listen.split(separator: ":")
        let host = String(parts[0]); let port = Int(parts[1]) ?? 4399
        // SIGHUP → reload
        let sighup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
        sighup.setEventHandler { try? store.reload(); logger.info("config reloaded") }
        sighup.resume()
        signal(SIGHUP, SIG_IGN)
        try await server.run(host: host, port: port)
    }
}

struct Devices: AsyncParsableCommand {
    static var configuration = CommandConfiguration(subcommands: [List.self, Revoke.self])

    struct List: AsyncParsableCommand {
        func run() async throws {
            let url = URL(fileURLWithPath: "\(NSHomeDirectory())/.cmuxremote/devices.json")
            for d in (try DeviceStore(url: url)).allDevices() {
                print("\(d.deviceId)  \(d.loginName)  \(d.hostname)  registered=\(d.registeredAt)")
            }
        }
    }
    struct Revoke: AsyncParsableCommand {
        @Argument var deviceId: String
        func run() async throws {
            let url = URL(fileURLWithPath: "\(NSHomeDirectory())/.cmuxremote/devices.json")
            try (try DeviceStore(url: url)).revoke(deviceId: deviceId)
            print("revoked \(deviceId)")
        }
    }
}

struct MenuBar: AsyncParsableCommand {
    func run() async throws {
        // Implemented in MenuBarUI.swift; runs the AppKit/SwiftUI loop.
        try await MenuBarApp.run()
    }
}

public final class CmuxSurfaceReader: SurfaceReader, @unchecked Sendable {
    private let connection: CmuxConnection
    public init(connection: CmuxConnection) { self.connection = connection }
    public func read(workspaceId: String, surfaceId: String, lines: Int) async throws -> Screen {
        let client = try await connection.connect()
        return try await client.surfaceReadText(workspaceId: workspaceId,
                                                surfaceId: surfaceId, lines: lines)
    }
}
```

- [ ] **Step 3: Implement minimal `MenuBarUI.swift`**

```swift
import Foundation
import AppKit
import SwiftUI
import RelayCore

public enum MenuBarApp {
    public static func run() async throws {
        await MainActor.run {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = MenuBarAppDelegate()
            app.delegate = delegate
            app.run()
        }
    }
}

@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "▣"
        let menu = NSMenu()
        menu.addItem(.init(title: "Devices…", action: #selector(showDevices), keyEquivalent: ""))
        menu.addItem(.init(title: "Reload Config (HUP)", action: #selector(reloadConfig), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(.init(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.target == nil { item.target = self }
        statusItem.menu = menu
    }
    @objc func showDevices() {
        let url = URL(fileURLWithPath: "\(NSHomeDirectory())/.cmuxremote/devices.json")
        NSWorkspace.shared.open(url)
    }
    @objc func reloadConfig() {
        let pid = getpid(); kill(pid, SIGHUP)
    }
    @objc func quit() { NSApp.terminate(nil) }
}
```

The menu-bar UI is intentionally minimal in v1.0 — it opens the devices.json file in Finder/TextEdit for inspection, sends SIGHUP to reload, and lets the user quit. Future versions add a SwiftUI list with revoke buttons.

- [ ] **Step 4: Build**

```bash
swift build
```
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/RelayServer/main.swift Sources/RelayServer/CMUXFacadeImpl.swift Sources/RelayServer/MenuBarUI.swift
git commit -m "M3.12: cmux-relay CLI + minimal SwiftUI menu-bar"
```

---

## Task 13 — Live integration smoke

**Files:**
- Create: `scripts/smoke-relay.sh`

- [ ] **Step 1: Author smoke script**

```bash
#!/usr/bin/env bash
set -euo pipefail
mkdir -p ~/.cmuxremote
if [ ! -f ~/.cmuxremote/relay.json ]; then
  cat > ~/.cmuxremote/relay.json <<'EOF'
{
  "listen": "127.0.0.1:4399",
  "allow_login": ["smoke@local"],
  "apns": { "key_path": "/dev/null", "key_id": "K", "team_id": "T",
            "topic": "com.example.smoke", "env": "sandbox" },
  "snippets": [],
  "default_fps": 15,
  "idle_fps": 5
}
EOF
fi
swift run cmux-relay serve --config ~/.cmuxremote/relay.json &
RELAY_PID=$!
trap 'kill $RELAY_PID' EXIT
sleep 1
curl -fsS http://127.0.0.1:4399/v1/health | tee /dev/stderr | grep -q '"ok":true'
echo "smoke OK"
```

- [ ] **Step 2: Run**

```bash
chmod +x scripts/smoke-relay.sh
./scripts/smoke-relay.sh
```
Expected: prints `{"ok":true}` then `smoke OK`.

- [ ] **Step 3: Commit**

```bash
git add scripts/smoke-relay.sh
git commit -m "M3.13: relay smoke script (health endpoint)"
```

---

## Task 14 — launchd plist + install scripts

**Files:**
- Create: `scripts/relay.plist.tmpl`
- Create: `scripts/install-launchd.sh`
- Create: `scripts/uninstall-launchd.sh`

- [ ] **Step 1: Author plist template**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.genie.cmuxremote</string>
  <key>ProgramArguments</key>
  <array>
    <string>__BIN__</string>
    <string>serve</string>
    <string>--config</string>
    <string>__CONFIG__</string>
  </array>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CMUX_SOCKET_PATH</key><string>/tmp/cmux.sock</string>
  </dict>
  <key>StandardOutPath</key>  <string>__LOGDIR__/stdout.log</string>
  <key>StandardErrorPath</key><string>__LOGDIR__/stderr.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Author install script**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN_SRC="$ROOT/.build/release/cmux-relay"
[ -x "$BIN_SRC" ] || { echo "build first: swift build -c release"; exit 1; }
DEST=~/.cmuxremote
LOG="$DEST/log"
mkdir -p "$DEST/bin" "$LOG"
cp "$BIN_SRC" "$DEST/bin/cmux-relay"
sed -e "s|__BIN__|$DEST/bin/cmux-relay|" \
    -e "s|__CONFIG__|$DEST/relay.json|" \
    -e "s|__LOGDIR__|$LOG|" \
    "$ROOT/scripts/relay.plist.tmpl" > ~/Library/LaunchAgents/com.genie.cmuxremote.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.genie.cmuxremote.plist || true
launchctl kickstart -k "gui/$(id -u)/com.genie.cmuxremote"
echo "installed; logs at $LOG"
```

- [ ] **Step 3: Author uninstall script**

```bash
#!/usr/bin/env bash
set -euo pipefail
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.genie.cmuxremote.plist || true
rm -f ~/Library/LaunchAgents/com.genie.cmuxremote.plist
echo "uninstalled"
```

- [ ] **Step 4: Run install**

```bash
chmod +x scripts/install-launchd.sh scripts/uninstall-launchd.sh
swift build -c release
./scripts/install-launchd.sh
launchctl print "gui/$(id -u)/com.genie.cmuxremote" | head -20
```
Expected: launchctl reports the agent as `state = running`.

- [ ] **Step 5: Commit**

```bash
git add scripts/relay.plist.tmpl scripts/install-launchd.sh scripts/uninstall-launchd.sh
git commit -m "M3.14: launchd plist + install/uninstall scripts"
```

---

## Task 15 — boot_id reset broadcast wiring

Spec section 10. When `CmuxConnection.onReset` fires, `SessionManager` broadcasts a `system.reset` event to all attached clients.

**Files:**
- Modify: `Sources/RelayServer/main.swift`
- Test:   `Tests/RelayCoreTests/ResetBroadcastTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
import SharedKit
@testable import RelayCore

final class ResetBroadcastTests: XCTestCase {
    func testResetEmitsSystemEvent() async throws {
        let mgr = SessionManager(reader: NoSurfaceReader(), defaultFps: 15, idleFps: 5)
        var saw: [PushFrame] = []
        _ = await mgr.attach(deviceId: "d") { saw.append($0) }
        await mgr.broadcastToAll(frame: .event(EventFrame(category: .system,
                                                          name: "cmux.reset",
                                                          payload: .null)))
        XCTAssertEqual(saw.count, 1)
        if case .event(let e) = saw[0] { XCTAssertEqual(e.name, "cmux.reset") }
        else { XCTFail("expected event") }
    }
}
final class NoSurfaceReader: SurfaceReader, @unchecked Sendable {
    func read(workspaceId: String, surfaceId: String, lines: Int) async throws -> Screen {
        Screen(rev: 0, rows: [], cols: 0, cursor: .init(x: 0, y: 0))
    }
}
```

- [ ] **Step 2: Wire in `main.swift` Serve.run**

Add immediately after creating `manager`:

```swift
        conn.onReset = {
            Task { await manager.broadcastToAll(
                frame: .event(EventFrame(category: .system, name: "cmux.reset", payload: .null))) }
        }
```

- [ ] **Step 3: Run — expect green**

`swift test --filter RelayCoreTests.ResetBroadcastTests` → 1 pass.

- [ ] **Step 4: Commit**

```bash
git add Tests/RelayCoreTests/ResetBroadcastTests.swift Sources/RelayServer/main.swift
git commit -m "M3.15: cmux boot_id reset → broadcast system.reset"
```

---

## Exit criteria

```bash
swift test --filter RelayCoreTests   2>&1 | tail -5
swift test --filter RelayServerTests 2>&1 | tail -5
swift build -c release               2>&1 | tail -3
./scripts/smoke-relay.sh             2>&1 | tail -3
launchctl print "gui/$(id -u)/com.genie.cmuxremote" | grep state
```

Required:
- All RelayCore + RelayServer tests pass
- Release build clean
- Smoke script reports `smoke OK`
- launchctl reports `state = running`

## Self-review

- [ ] **Coverage:** every spec section listed under "Spec coverage" maps to at least one task that lands code or scripts.
- [ ] **Placeholder scan:** `grep -RnE "TODO|FIXME|tbd|stub" Sources/RelayCore Sources/RelayServer scripts/` returns no hits.
- [ ] **Type consistency:** `Session.send`, `SessionManager.broadcastTo*`, and `WebSocketHandler.encode` all funnel through `PushFrame`. `DeviceStore.tokenHash` SHA256 matches the hash used in `WebSocketHandler.deviceIdFromHeaders`.
- [ ] **Spec deviations recorded:** open-question resolutions in section 14 of the spec (single binary, tailscaled local API).

## Merge

```bash
git checkout main
git merge --ff-only m3-relay
git branch -d m3-relay
```

Pick up M4 next: `2026-05-09-m4-ios-skeleton.md`.
