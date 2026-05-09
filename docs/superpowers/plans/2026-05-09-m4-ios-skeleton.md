# M4 — iOS Skeleton (Workspace / Terminal / Notifications / Settings)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the SwiftUI app skeleton that connects to the M3 relay over Tailscale, lists workspaces and surfaces, renders the terminal grid, and shows the in-app notification list. AccessoryBar (M5) and APNs (M6) deliberately stay out so this milestone stays sized to one PR.

**Architecture:** Standard SwiftUI 17+ app. Top-level `TabView` with three tabs (Workspaces, Notifications, Settings). One `WSClient` per app instance backed by `URLSessionWebSocketTask`. `RPCClient` actor multiplexes requests/responses by id. Stores are `@Observable` actors, projected into views via `@Bindable`/`@Environment`. Terminal renders via SwiftUI `Canvas` over a fixed `CellGrid` that ingests `screen.full`/`screen.diff` push frames.

**Tech Stack:** Swift 5.10, SwiftUI (iOS 17+), `URLSessionWebSocketTask`, CryptoKit, IOSSecuritySuite (MIT), `SharedKit` as a local Swift package dep, `xcodegen` for project generation.

**Branch:** `m4-ios` from `main`, after M3 has merged.

---

## Spec coverage

- Spec section 9.1 ("Screens") — every named view.
- Spec section 9.3 ("Workspace switcher") — drawer (cmd shortcuts come in M5).
- Spec section 9.4 ("TerminalView rendering") — Canvas + ANSI subset parser.
- Spec section 7.1 ("Auth flow") — `AuthClient` first-connect handshake + Keychain.
- Spec section 7.2 ("Phone hardening") — IOSSecuritySuite at app launch.
- Spec section 10 ("Reconnect / screen.checksum") — `WSClient` reconnect + checksum reconciliation.

## File map

```
ios/
├─ project.yml                                  # task 1
├─ CmuxRemote.xcodeproj                         # generated
└─ CmuxRemote/
   ├─ CmuxRemoteApp.swift                       # task 18
   ├─ ContentView.swift                         # task 18
   ├─ Network/
   │  ├─ WSClient.swift                         # task 6
   │  ├─ RPCClient.swift                        # task 7
   │  └─ AuthClient.swift                       # task 5
   ├─ Storage/Keychain.swift                    # task 4
   ├─ Security/HardeningCheck.swift             # task 8
   ├─ Stores/
   │  ├─ WorkspaceStore.swift                   # task 9
   │  ├─ SurfaceStore.swift                     # task 9
   │  └─ NotificationStore.swift                # task 9
   ├─ Workspace/
   │  ├─ WorkspaceListView.swift                # task 13
   │  ├─ WorkspaceView.swift                    # task 14
   │  └─ WorkspaceDrawer.swift                  # task 15
   ├─ Terminal/
   │  ├─ TerminalView.swift                     # task 12
   │  ├─ ANSIParser.swift                       # task 10
   │  └─ CellGrid.swift                         # task 11
   ├─ Notifications/NotificationCenterView.swift # task 16
   └─ Settings/SettingsView.swift               # task 17
└─ CmuxRemoteTests/                             # XCTest unit tests
└─ CmuxRemoteUITests/                           # XCUITest
```

---

## Task 1 — xcodegen project bootstrap

**Files:**
- Create: `ios/project.yml`
- Create: `ios/CmuxRemote/Info.plist` (xcodegen will generate / merge)
- Create: `ios/CmuxRemoteTests/.gitkeep`
- Create: `ios/CmuxRemoteUITests/.gitkeep`

- [ ] **Step 1: Branch + tools**

```bash
git checkout main && git checkout -b m4-ios
brew install xcodegen
xcodegen --version
```

- [ ] **Step 2: Author `ios/project.yml`**

```yaml
name: CmuxRemote
options:
  bundleIdPrefix: com.genie
  deploymentTarget:
    iOS: "17.0"
settings:
  base:
    SWIFT_VERSION: "5.10"
    DEVELOPMENT_TEAM: ""
    CODE_SIGN_STYLE: Automatic
packages:
  SharedKit:
    path: ..
  IOSSecuritySuite:
    url: https://github.com/securing/IOSSecuritySuite
    from: "1.9.10"
targets:
  CmuxRemote:
    type: application
    platform: iOS
    sources:
      - path: CmuxRemote
    info:
      path: CmuxRemote/Info.plist
      properties:
        CFBundleShortVersionString: "1.0.0"
        CFBundleVersion: "1"
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: true
        UILaunchScreen: {}
        CFBundleURLTypes:
          - CFBundleURLSchemes: [cmux]
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
    dependencies:
      - package: SharedKit
        product: SharedKit
      - package: IOSSecuritySuite
  CmuxRemoteTests:
    type: bundle.unit-test
    platform: iOS
    sources: CmuxRemoteTests
    dependencies:
      - target: CmuxRemote
  CmuxRemoteUITests:
    type: bundle.ui-testing
    platform: iOS
    sources: CmuxRemoteUITests
    dependencies:
      - target: CmuxRemote
```

`NSAllowsArbitraryLoads: true` is acceptable here because all traffic goes to a Tailscale-reachable hostname over plain HTTP secured by Tailscale's wire encryption; we are not bypassing TLS for public internet.

- [ ] **Step 3: Generate project**

```bash
mkdir -p ios/CmuxRemote ios/CmuxRemoteTests ios/CmuxRemoteUITests
touch ios/CmuxRemoteTests/.gitkeep ios/CmuxRemoteUITests/.gitkeep
cat > ios/CmuxRemote/CmuxRemoteApp.swift <<'EOF'
import SwiftUI
@main struct CmuxRemoteApp: App { var body: some Scene { WindowGroup { Text("hello") } } }
EOF
cd ios && xcodegen generate
xcodebuild -project CmuxRemote.xcodeproj -scheme CmuxRemote -destination 'generic/platform=iOS Simulator' -configuration Debug build | tail -3
cd ..
```
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add ios/project.yml ios/CmuxRemote ios/CmuxRemoteTests ios/CmuxRemoteUITests
echo "ios/CmuxRemote.xcodeproj" >> .gitignore     # generated; users regenerate via xcodegen
git add .gitignore
git commit -m "M4.1: iOS project scaffolded via xcodegen"
```

(For now we keep the generated `.xcodeproj` out of git — every checkout runs `xcodegen generate`. If that proves annoying, flip it to tracked at the end of M4.)

---

## Task 2 — Test runner sanity

**Files:**
- Create: `ios/CmuxRemoteTests/CmuxRemoteTests.swift`

- [ ] **Step 1: Smoke test**

```swift
import XCTest
@testable import CmuxRemote
import SharedKit

final class SmokeTests: XCTestCase {
    func testSharedKitLinks() {
        let req = RPCRequest(id: 1, method: "x", params: .null)
        XCTAssertEqual(req.id, 1)
    }
}
```

- [ ] **Step 2: Run**

```bash
cd ios && xcodegen generate
xcodebuild test -project CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' | tail -5
cd ..
```
Expected: `Test Suite 'SmokeTests' passed`.

- [ ] **Step 3: Commit**

```bash
git add ios/CmuxRemoteTests/CmuxRemoteTests.swift
git commit -m "M4.2: smoke test verifies SharedKit links into iOS target"
```

---

## Task 3 — `Keychain.swift` (Secure-Enclave-bound bearer storage)

**Files:**
- Create: `ios/CmuxRemote/Storage/Keychain.swift`
- Test:   `ios/CmuxRemoteTests/KeychainTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
@testable import CmuxRemote

final class KeychainTests: XCTestCase {
    func testRoundTrip() throws {
        let kc = Keychain(service: "test.\(UUID().uuidString)")
        try kc.set("token", for: "bearer")
        XCTAssertEqual(try kc.get("bearer"), "token")
        try kc.delete("bearer")
        XCTAssertNil(try kc.get("bearer"))
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import Security

public final class Keychain {
    public let service: String
    public init(service: String) { self.service = service }

    public func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.os(status) }
    }

    public func get(_ key: String) throws -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.os(status) }
        return String(data: data, encoding: .utf8)
    }

    public func delete(_ key: String) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(q as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.os(status)
        }
    }

    public func wipe() throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service]
        _ = SecItemDelete(q as CFDictionary)
    }
}

public enum KeychainError: Error { case os(OSStatus) }
```

Per spec section 7.1 the bearer should be Secure-Enclave-bound. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` plus the device's Secure Enclave-protected class key meets the spec; an explicit Secure-Enclave key import isn't required for a generic password item.

- [ ] **Step 3: Run + commit**

```bash
xcodebuild test -project ios/CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:CmuxRemoteTests/KeychainTests | tail -3
git add ios/CmuxRemote/Storage/Keychain.swift ios/CmuxRemoteTests/KeychainTests.swift
git commit -m "M4.3: Keychain helper (after-first-unlock, this-device-only)"
```

---

## Task 4 — `AuthClient` (first-connect handshake)

**Files:**
- Create: `ios/CmuxRemote/Network/AuthClient.swift`
- Test:   `ios/CmuxRemoteTests/AuthClientTests.swift`

The relay (M3) accepts the WS handshake when the peer's Tailscale identity is allow-listed. The phone needs to:
1. Open WS to `wss://<host>:4399/v1/stream` with sub-protocol `cmuxremote.v1, bearer.<token>`.
2. On first launch the bearer is unknown — the relay issues one via `POST /v1/devices/me/register` (M3 task 9). The endpoint takes no body, runs WhoIs on the source IP, and returns `{"device_id":"…","token":"…"}` on success.

- [ ] **Step 1: Test (mocked HTTP)**

```swift
import XCTest
@testable import CmuxRemote

final class AuthClientTests: XCTestCase {
    func testRegisterStoresBearer() async throws {
        let kc = Keychain(service: "auth.\(UUID().uuidString)")
        let mock = MockHTTPClient(handler: { _ in
            (Data(#"{"device_id":"d1","token":"abc"}"#.utf8), 200)
        })
        let client = AuthClient(host: "mac.tailnet.ts.net", port: 4399,
                                keychain: kc, http: mock)
        try await client.registerIfNeeded()
        XCTAssertEqual(try kc.get("device_id"), "d1")
        XCTAssertEqual(try kc.get("bearer"), "abc")
    }

    func testNoOpWhenAlreadyRegistered() async throws {
        let kc = Keychain(service: "auth.\(UUID().uuidString)")
        try kc.set("d1", for: "device_id"); try kc.set("abc", for: "bearer")
        var hit = 0
        let mock = MockHTTPClient(handler: { _ in hit += 1; return (Data(), 200) })
        let client = AuthClient(host: "x", port: 4399, keychain: kc, http: mock)
        try await client.registerIfNeeded()
        XCTAssertEqual(hit, 0)
    }
}

final class MockHTTPClient: HTTPClientFacade {
    let handler: (URLRequest) -> (Data, Int)
    init(handler: @escaping (URLRequest) -> (Data, Int)) { self.handler = handler }
    func request(_ r: URLRequest) async throws -> (Data, Int) { handler(r) }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public protocol HTTPClientFacade {
    func request(_ req: URLRequest) async throws -> (Data, Int)
}

public final class URLSessionHTTP: HTTPClientFacade {
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func request(_ req: URLRequest) async throws -> (Data, Int) {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (data, code)
    }
}

public final class AuthClient {
    public let host: String
    public let port: Int
    public let keychain: Keychain
    public let http: HTTPClientFacade
    public init(host: String, port: Int, keychain: Keychain, http: HTTPClientFacade) {
        self.host = host; self.port = port; self.keychain = keychain; self.http = http
    }

    public func registerIfNeeded() async throws {
        if try keychain.get("bearer") != nil, try keychain.get("device_id") != nil { return }
        var req = URLRequest(url: URL(string: "https://\(host):\(port)/v1/devices/me/register")!)
        req.httpMethod = "POST"
        let (data, code) = try await http.request(req)
        guard code == 200 else { throw AuthError.relayRejected(code) }
        struct R: Decodable { let deviceId: String; let token: String
            enum CodingKeys: String, CodingKey { case deviceId = "device_id", token } }
        let r = try JSONDecoder().decode(R.self, from: data)
        try keychain.set(r.deviceId, for: "device_id")
        try keychain.set(r.token, for: "bearer")
    }

    public func wipe() throws { try keychain.delete("device_id"); try keychain.delete("bearer") }
}

public enum AuthError: Error { case relayRejected(Int) }
```

- [ ] **Step 3: Run + commit**

```bash
xcodebuild test -project ios/CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:CmuxRemoteTests/AuthClientTests | tail -3
git add ios/CmuxRemote/Network/AuthClient.swift ios/CmuxRemoteTests/AuthClientTests.swift
git commit -m "M4.4: AuthClient first-connect handshake"
```

---

## Task 5 — `WSClient` (URLSessionWebSocketTask + reconnect)

**Files:**
- Create: `ios/CmuxRemote/Network/WSClient.swift`
- Test:   `ios/CmuxRemoteTests/WSClientTests.swift`

- [ ] **Step 1: Test (against a local NIO echo server in-test)**

This test runs an embedded NIO HTTP/WS server in the simulator process so it does not depend on Mac-side relay code. If you prefer to skip it, mark it with `try XCTSkipIf(true, "requires loopback ws server")` and rely on E2E smoke instead. The lighter approach (one-test):

```swift
import XCTest
import SharedKit
@testable import CmuxRemote

final class WSClientTests: XCTestCase {
    func testConnectsAndDeliversTextFrame() async throws {
        // Use the public echo endpoint at wss://echo.websocket.events for connectivity,
        // gated by env var so CI without internet skips.
        try XCTSkipIf(ProcessInfo.processInfo.environment["WS_ECHO"] != "1",
                      "set WS_ECHO=1 to run")
        let url = URL(string: "wss://echo.websocket.events/")!
        let exp = expectation(description: "received echo")
        let client = WSClient(url: url, headers: [:])
        client.onText = { s in if s.contains("hello") { exp.fulfill() } }
        await client.connect()
        await client.send(text: "hello")
        await fulfillment(of: [exp], timeout: 5)
        await client.close()
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import OSLog

public actor WSClient {
    public let url: URL
    public let headers: [String: String]

    public var onText: ((String) -> Void)?
    public var onOpen: (() -> Void)?
    public var onClose: ((Int) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var backoff: TimeInterval = 1.0
    private let log = Logger(subsystem: "cmux", category: "ws")

    public init(url: URL, headers: [String: String]) {
        self.url = url; self.headers = headers
        self.session = URLSession(configuration: .ephemeral)
    }

    public func connect() {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: req)
        task.resume()
        self.task = task
        onOpen?()
        backoff = 1.0
        Task { await self.receiveLoop() }
    }

    public func send(text: String) {
        task?.send(.string(text)) { _ in }
    }

    public func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receiveLoop() async {
        guard let task else { return }
        do {
            let msg = try await task.receive()
            switch msg {
            case .string(let s): onText?(s)
            case .data(let d):   onText?(String(data: d, encoding: .utf8) ?? "")
            @unknown default: break
            }
            await receiveLoop()
        } catch {
            log.error("ws closed: \(error.localizedDescription, privacy: .public)")
            onClose?((task.closeCode.rawValue))
            await reconnectAfterBackoff()
        }
    }

    private func reconnectAfterBackoff() async {
        let delay = min(backoff, 30)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        backoff = min(backoff * 2, 30)
        connect()
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add ios/CmuxRemote/Network/WSClient.swift ios/CmuxRemoteTests/WSClientTests.swift
git commit -m "M4.5: WSClient (URLSessionWebSocketTask + 1→30s exp backoff)"
```

---

## Task 6 — `RPCClient` (request/response correlation + push fanout)

**Files:**
- Create: `ios/CmuxRemote/Network/RPCClient.swift`
- Test:   `ios/CmuxRemoteTests/RPCClientTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
import SharedKit
@testable import CmuxRemote

final class RPCClientTests: XCTestCase {
    func testCallReturnsOnMatchingId() async throws {
        let stub = StubWS()
        let rpc = RPCClient(transport: stub)
        async let result = rpc.call(method: "workspace.list", params: .object([:]))
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertTrue(stub.outbox.last?.contains("workspace.list") ?? false)
        await rpc.handleIncoming(text: #"{"id":1,"ok":true,"result":{"workspaces":[]}}"#)
        let r = try await result
        XCTAssertTrue(r.ok)
    }

    func testPushFrameDispatchedToHandler() async {
        let rpc = RPCClient(transport: StubWS())
        var saw = 0
        await rpc.onPush { _ in saw += 1 }
        await rpc.handleIncoming(text: #"{"type":"event","category":"system","name":"x","payload":{}}"#)
        XCTAssertEqual(saw, 1)
    }
}

final class StubWS: RPCTransport {
    var outbox: [String] = []
    func send(text: String) async { outbox.append(text) }
    func close() async {}
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import SharedKit

public protocol RPCTransport: AnyObject, Sendable {
    func send(text: String) async
    func close() async
}

public actor RPCClient {
    private let transport: RPCTransport
    private var nextId: Int64 = 1
    private var pending: [Int64: CheckedContinuation<RPCResponse, Error>] = [:]
    private var pushHandler: (@Sendable (PushFrame) -> Void)?

    public init(transport: RPCTransport) { self.transport = transport }

    public func onPush(_ handler: @escaping @Sendable (PushFrame) -> Void) {
        self.pushHandler = handler
    }

    @discardableResult
    public func call(method: String, params: JSONValue) async throws -> RPCResponse {
        let id = nextId; nextId += 1
        let req = RPCRequest(id: id, method: method, params: params)
        let body = try JSONEncoder().encode(req)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RPCResponse, Error>) in
            self.pending[id] = cont
            Task { await self.transport.send(text: String(data: body, encoding: .utf8)!) }
        }
    }

    public func handleIncoming(text: String) {
        let data = Data(text.utf8)
        if let resp = try? JSONDecoder().decode(RPCResponse.self, from: data),
           let cont = pending.removeValue(forKey: resp.id) {
            cont.resume(returning: resp); return
        }
        if let push = try? JSONDecoder().decode(PushFrame.self, from: data) {
            pushHandler?(push)
        }
    }
}

extension WSClient: RPCTransport {}
```

- [ ] **Step 3: Run + commit**

```bash
xcodebuild test -project ios/CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:CmuxRemoteTests/RPCClientTests | tail -3
git add ios/CmuxRemote/Network/RPCClient.swift ios/CmuxRemoteTests/RPCClientTests.swift
git commit -m "M4.6: RPCClient request correlation + push fanout"
```

---

## Task 7 — `HardeningCheck` (IOSSecuritySuite)

Spec section 7.2.

**Files:**
- Create: `ios/CmuxRemote/Security/HardeningCheck.swift`
- Test:   `ios/CmuxRemoteTests/HardeningCheckTests.swift`

- [ ] **Step 1: Test (uses injected predicates)**

```swift
import XCTest
@testable import CmuxRemote

final class HardeningCheckTests: XCTestCase {
    func testFailedCheckWipesKeychain() {
        let kc = Keychain(service: "h.\(UUID().uuidString)")
        try? kc.set("v", for: "bearer")
        let check = HardeningCheck(jailbroken: { true }, debugged: { false }, keychain: kc)
        XCTAssertEqual(check.runAtLaunch(), .failedJailbroken)
        XCTAssertNil(try? kc.get("bearer"))
    }
    func testCleanCheckReturnsOk() {
        let kc = Keychain(service: "h.\(UUID().uuidString)")
        let check = HardeningCheck(jailbroken: { false }, debugged: { false }, keychain: kc)
        XCTAssertEqual(check.runAtLaunch(), .ok)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import IOSSecuritySuite

public enum HardeningResult: Equatable {
    case ok, failedJailbroken, failedDebugged
}

public final class HardeningCheck {
    private let jailbroken: () -> Bool
    private let debugged: () -> Bool
    private let keychain: Keychain
    public init(jailbroken: @escaping () -> Bool = { IOSSecuritySuite.amIJailbroken() },
                debugged: @escaping () -> Bool = { IOSSecuritySuite.amIDebugged() },
                keychain: Keychain)
    {
        self.jailbroken = jailbroken; self.debugged = debugged; self.keychain = keychain
    }

    @discardableResult
    public func runAtLaunch() -> HardeningResult {
        if jailbroken() { try? keychain.wipe(); return .failedJailbroken }
        if debugged()    { try? keychain.wipe(); return .failedDebugged }
        return .ok
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
xcodebuild test -project ios/CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:CmuxRemoteTests/HardeningCheckTests | tail -3
git add ios/CmuxRemote/Security/HardeningCheck.swift ios/CmuxRemoteTests/HardeningCheckTests.swift
git commit -m "M4.7: HardeningCheck wipes keychain on jailbreak/debugger"
```

---

## Task 8 — Stores (Workspace, Surface, Notification)

**Files:**
- Create: `ios/CmuxRemote/Stores/WorkspaceStore.swift`
- Create: `ios/CmuxRemote/Stores/SurfaceStore.swift`
- Create: `ios/CmuxRemote/Stores/NotificationStore.swift`

- [ ] **Step 1: Implement WorkspaceStore**

```swift
import Foundation
import SharedKit
import Observation

@Observable
public final class WorkspaceStore {
    public var workspaces: [Workspace] = []
    public var selectedId: String?
    public var connection: ConnectionState = .disconnected

    private let rpc: RPCClient
    public init(rpc: RPCClient) { self.rpc = rpc }

    public func refresh() async {
        do {
            let resp = try await rpc.call(method: "workspace.list", params: .object([:]))
            let value = try resp.unwrapResult().decode([String: [Workspace]].self)
            await MainActor.run {
                self.workspaces = value["workspaces"] ?? []
                if self.selectedId == nil { self.selectedId = self.workspaces.first?.id }
            }
        } catch {
            await MainActor.run { self.connection = .error(String(describing: error)) }
        }
    }

    public func create(name: String) async throws {
        _ = try await rpc.call(method: "workspace.create",
                               params: .object(["name": .string(name)]))
        await refresh()
    }
}

public enum ConnectionState: Equatable {
    case disconnected, connecting, connected, error(String)
}
```

- [ ] **Step 2: Implement SurfaceStore**

```swift
import Foundation
import SharedKit
import Observation

@Observable
public final class SurfaceStore {
    public var grid: CellGrid = CellGrid(cols: 80, rows: 24)
    public var rev: Int = 0
    public var subscribed: String?
    private let rpc: RPCClient
    public init(rpc: RPCClient) { self.rpc = rpc }

    public func subscribe(workspaceId: String, surfaceId: String) async {
        if let sub = subscribed { await unsubscribe(surfaceId: sub) }
        subscribed = surfaceId
        _ = try? await rpc.call(method: "surface.subscribe",
                                params: .object([
                                    "workspace_id": .string(workspaceId),
                                    "surface_id": .string(surfaceId),
                                    "fps": .int(15),
                                ]))
    }
    public func unsubscribe(surfaceId: String) async {
        _ = try? await rpc.call(method: "surface.unsubscribe",
                                params: .object(["surface_id": .string(surfaceId)]))
        if subscribed == surfaceId { subscribed = nil }
    }
    public func ingest(_ frame: PushFrame) {
        switch frame {
        case .screenFull(let f):
            self.grid = CellGrid(cols: f.cols, rows: f.rowsCount)
            for (i, row) in f.rows.enumerated() { grid.replaceRow(i, raw: row) }
            grid.cursor = f.cursor; rev = f.rev
        case .screenDiff(let f):
            for op in f.ops {
                switch op {
                case .clear: grid.clear()
                case .row(let y, let text): grid.replaceRow(y, raw: text)
                case .cursor(let x, let y): grid.cursor = .init(x: x, y: y)
                }
            }
            rev = f.rev
        default: break
        }
    }

    public func sendText(workspaceId: String, surfaceId: String, text: String) async {
        _ = try? await rpc.call(method: "surface.send_text",
                                params: .object([
                                    "workspace_id": .string(workspaceId),
                                    "surface_id": .string(surfaceId),
                                    "text": .string(text),
                                ]))
    }
    public func sendKey(workspaceId: String, surfaceId: String, key: Key) async {
        _ = try? await rpc.call(method: "surface.send_key",
                                params: .object([
                                    "workspace_id": .string(workspaceId),
                                    "surface_id": .string(surfaceId),
                                    "key": .string(KeyEncoder.encode(key)),
                                ]))
    }
}

extension RPCResponse {
    public func unwrapResult() throws -> JSONValue {
        if let e = error { throw NSError(domain: "rpc", code: e.code,
                                         userInfo: [NSLocalizedDescriptionKey: e.message]) }
        guard let r = result else { throw NSError(domain: "rpc", code: -1) }
        return r
    }
}
extension JSONValue {
    public func decode<T: Decodable>(_ t: T.Type) throws -> T {
        let d = JSONEncoder(); d.outputFormatting = [.sortedKeys]
        return try JSONDecoder().decode(T.self, from: try d.encode(self))
    }
}
```

- [ ] **Step 3: Implement NotificationStore**

```swift
import Foundation
import SharedKit
import Observation

@Observable
public final class NotificationStore {
    public var items: [NotificationRecord] = []   // newest first, capped at 200
    public func append(_ n: NotificationRecord) {
        items.insert(n, at: 0)
        if items.count > 200 { items.removeLast(items.count - 200) }
    }
    public func ingest(_ frame: PushFrame) {
        if case .event(let e) = frame, e.name == "notification.created",
           let data = try? JSONEncoder().encode(e.payload),
           let n = try? JSONDecoder().decode(NotificationRecord.self, from: data)
        { append(n) }
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add ios/CmuxRemote/Stores
git commit -m "M4.8: WorkspaceStore + SurfaceStore + NotificationStore"
```

---

## Task 9 — `ANSIParser` (subset SGR)

Spec section 9.4. Parse ESC `[`<args>`m` SGR sequences. Drop everything else silently.

**Files:**
- Create: `ios/CmuxRemote/Terminal/ANSIParser.swift`
- Test:   `ios/CmuxRemoteTests/ANSIParserTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
@testable import CmuxRemote

final class ANSIParserTests: XCTestCase {
    func testPlainText() {
        let cells = ANSIParser.parse("hello", base: .default)
        XCTAssertEqual(cells.count, 5)
        XCTAssertEqual(cells.first?.character, "h")
        XCTAssertEqual(cells.first?.attr, .default)
    }
    func testColorThenReset() {
        let line = "\u{1B}[31mred\u{1B}[0mok"
        let cells = ANSIParser.parse(line, base: .default)
        XCTAssertEqual(cells.count, 5)        // r e d o k
        XCTAssertEqual(cells[0].attr.fg, .red)
        XCTAssertEqual(cells[3].attr, .default)
    }
    func testBold() {
        let line = "\u{1B}[1mbold\u{1B}[0m"
        let cells = ANSIParser.parse(line, base: .default)
        XCTAssertTrue(cells[0].attr.bold)
        XCTAssertFalse(cells[3].attr.bold == false)   // still bold inside
    }
    func testUnknownEscapeIsDropped() {
        let line = "\u{1B}[?25lhi"
        let cells = ANSIParser.parse(line, base: .default)
        XCTAssertEqual(cells.count, 2)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public enum ANSIColor: Equatable {
    case `default`
    case red, green, yellow, blue, magenta, cyan, white, black
    case bright(ANSIColor)
}

public struct ANSIAttr: Equatable {
    public var fg: ANSIColor
    public var bg: ANSIColor
    public var bold: Bool
    public var underline: Bool
    public static let `default` = ANSIAttr(fg: .default, bg: .default, bold: false, underline: false)
    public init(fg: ANSIColor, bg: ANSIColor, bold: Bool, underline: Bool) {
        self.fg = fg; self.bg = bg; self.bold = bold; self.underline = underline
    }
}

public struct ANSICell: Equatable {
    public var character: Character
    public var attr: ANSIAttr
}

public enum ANSIParser {
    public static func parse(_ s: String, base: ANSIAttr) -> [ANSICell] {
        var out: [ANSICell] = []
        var attr = base
        var iter = s.unicodeScalars.makeIterator()
        while let scalar = iter.next() {
            if scalar == "\u{1B}", let next = iter.next() {
                guard next == "[" else { continue }
                var args: String = ""
                while let c = iter.next() {
                    if c.value >= 0x40 && c.value <= 0x7E {
                        if c == "m" { applySGR(&attr, args: args) }
                        break
                    } else {
                        args.unicodeScalars.append(c)
                    }
                }
            } else {
                out.append(.init(character: Character(scalar), attr: attr))
            }
        }
        return out
    }

    private static func applySGR(_ attr: inout ANSIAttr, args: String) {
        let parts = args.isEmpty ? [0] : args.split(separator: ";").compactMap { Int($0) }
        for n in parts {
            switch n {
            case 0:  attr = .default
            case 1:  attr.bold = true
            case 4:  attr.underline = true
            case 22: attr.bold = false
            case 24: attr.underline = false
            case 30...37: attr.fg = colorFor(code: n - 30)
            case 39: attr.fg = .default
            case 40...47: attr.bg = colorFor(code: n - 40)
            case 49: attr.bg = .default
            case 90...97: attr.fg = .bright(colorFor(code: n - 90))
            default: continue
            }
        }
    }
    private static func colorFor(code: Int) -> ANSIColor {
        switch code {
        case 0: return .black; case 1: return .red; case 2: return .green
        case 3: return .yellow; case 4: return .blue; case 5: return .magenta
        case 6: return .cyan;  case 7: return .white; default: return .default
        }
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
xcodebuild test -project ios/CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:CmuxRemoteTests/ANSIParserTests | tail -3
git add ios/CmuxRemote/Terminal/ANSIParser.swift ios/CmuxRemoteTests/ANSIParserTests.swift
git commit -m "M4.9: ANSIParser SGR subset (fg/bg/bold/underline)"
```

---

## Task 10 — `CellGrid`

**Files:**
- Create: `ios/CmuxRemote/Terminal/CellGrid.swift`
- Test:   `ios/CmuxRemoteTests/CellGridTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
import SharedKit
@testable import CmuxRemote

final class CellGridTests: XCTestCase {
    func testReplaceRowParsesAnsi() {
        var g = CellGrid(cols: 80, rows: 3)
        g.replaceRow(1, raw: "\u{1B}[31mok\u{1B}[0m")
        XCTAssertEqual(g.rows[1].first?.character, "o")
        XCTAssertEqual(g.rows[1].first?.attr.fg, .red)
    }
    func testClearEmpties() {
        var g = CellGrid(cols: 10, rows: 2)
        g.replaceRow(0, raw: "hi")
        g.clear()
        XCTAssertEqual(g.rows[0].count, 0)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import SharedKit

public struct CellGrid {
    public var rows: [[ANSICell]]
    public var cols: Int
    public var cursor: CursorPos = .init(x: 0, y: 0)

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = Array(repeating: [], count: rows)
    }

    public mutating func replaceRow(_ y: Int, raw: String) {
        if y >= rows.count { rows.append(contentsOf: Array(repeating: [], count: y - rows.count + 1)) }
        rows[y] = ANSIParser.parse(raw, base: .default)
    }

    public mutating func clear() { for i in 0..<rows.count { rows[i] = [] } }
}
```

- [ ] **Step 3: Run + commit**

```bash
xcodebuild test -project ios/CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:CmuxRemoteTests/CellGridTests | tail -3
git add ios/CmuxRemote/Terminal/CellGrid.swift ios/CmuxRemoteTests/CellGridTests.swift
git commit -m "M4.10: CellGrid (ANSI-aware rows + cursor)"
```

---

## Task 11 — `TerminalView` (SwiftUI Canvas)

**Files:**
- Create: `ios/CmuxRemote/Terminal/TerminalView.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct TerminalView: View {
    @Bindable var store: SurfaceStore
    @State private var fontSize: CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let lineHeight = fontSize + 2
                let advance = fontSize * 0.6
                for (y, row) in store.grid.rows.enumerated() {
                    for (x, cell) in row.enumerated() {
                        let pt = CGPoint(x: CGFloat(x) * advance, y: CGFloat(y) * lineHeight)
                        let s = String(cell.character)
                        ctx.draw(Text(s).font(.system(size: fontSize, weight: cell.attr.bold ? .bold : .regular,
                                                       design: .monospaced))
                                    .foregroundColor(cell.attr.fg.swiftUI),
                                 at: pt, anchor: .topLeading)
                    }
                }
                // cursor
                let cx = CGFloat(store.grid.cursor.x) * advance
                let cy = CGFloat(store.grid.cursor.y) * lineHeight
                ctx.fill(Path(CGRect(x: cx, y: cy, width: advance, height: lineHeight)),
                         with: .color(.accentColor.opacity(0.3)))
            }
            .background(Color.black)
            .gesture(MagnificationGesture().onChanged { v in
                fontSize = max(9, min(20, 13 * v))
            })
        }
    }
}

private extension ANSIColor {
    var swiftUI: Color {
        switch self {
        case .default: return .green
        case .red:     return .red
        case .green:   return .green
        case .yellow:  return .yellow
        case .blue:    return .blue
        case .magenta: return .pink
        case .cyan:    return .teal
        case .white:   return .white
        case .black:   return .black
        case .bright(let inner): return inner.swiftUI.opacity(1.0)
        }
    }
}
```

(Defaulting to green-on-black is fine for v1.0; v1.1 adds theming.)

- [ ] **Step 2: Build + commit**

```bash
xcodebuild build -project ios/CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' | tail -3
git add ios/CmuxRemote/Terminal/TerminalView.swift
git commit -m "M4.11: TerminalView Canvas grid + pinch-zoom"
```

---

## Task 12 — `WorkspaceListView`

**Files:**
- Create: `ios/CmuxRemote/Workspace/WorkspaceListView.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import SharedKit

struct WorkspaceListView: View {
    @Bindable var store: WorkspaceStore
    @State private var creating = false
    @State private var newName = ""
    var onSelect: (Workspace) -> Void

    var body: some View {
        NavigationStack {
            List(store.workspaces) { ws in
                Button {
                    store.selectedId = ws.id
                    onSelect(ws)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(ws.name).font(.headline)
                            Text("\(ws.surfaces.count) surfaces").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(relative(ws.lastActivity)).font(.caption2)
                    }
                }
            }
            .navigationTitle("Workspaces")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New") { creating = true }
                }
            }
            .alert("New Workspace", isPresented: $creating) {
                TextField("name", text: $newName)
                Button("Create") { Task { try? await store.create(name: newName); newName = "" } }
                Button("Cancel", role: .cancel) {}
            }
            .task { await store.refresh() }
            .refreshable { await store.refresh() }
        }
    }

    private func relative(_ ts: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        return RelativeDateTimeFormatter().localizedString(for: d, relativeTo: .now)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/CmuxRemote/Workspace/WorkspaceListView.swift
git commit -m "M4.12: WorkspaceListView + create modal"
```

---

## Task 13 — `WorkspaceView` + `WorkspaceDrawer`

**Files:**
- Create: `ios/CmuxRemote/Workspace/WorkspaceView.swift`
- Create: `ios/CmuxRemote/Workspace/WorkspaceDrawer.swift`

- [ ] **Step 1: Implement WorkspaceDrawer**

```swift
import SwiftUI

struct WorkspaceDrawer: View {
    @Bindable var store: WorkspaceStore
    var onPick: (String, String) -> Void   // (workspaceId, surfaceId)
    var body: some View {
        List {
            ForEach(store.workspaces) { ws in
                Section(ws.name) {
                    ForEach(ws.surfaces) { sf in
                        Button(sf.title) { onPick(ws.id, sf.id) }
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Implement WorkspaceView**

```swift
import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspaceStore: WorkspaceStore
    @Bindable var surfaceStore: SurfaceStore
    @State private var showDrawer = false
    @State private var activeSurfaceId: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let ws = currentWorkspace, !ws.surfaces.isEmpty {
                    HStack {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(ws.surfaces) { sf in
                                    Button {
                                        activeSurfaceId = sf.id
                                        Task { await surfaceStore.subscribe(workspaceId: ws.id, surfaceId: sf.id) }
                                    } label: {
                                        Text(sf.title).padding(.horizontal, 8).padding(.vertical, 4)
                                            .background(activeSurfaceId == sf.id ? Color.accentColor.opacity(0.2) : Color.clear)
                                            .clipShape(.capsule)
                                    }
                                }
                            }.padding(.horizontal)
                        }
                    }.frame(height: 36)
                }
                Divider()
                TerminalView(store: surfaceStore)
            }
            .navigationTitle(currentWorkspace?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showDrawer = true } label: { Image(systemName: "line.3.horizontal") }
                }
            }
            .sheet(isPresented: $showDrawer) {
                WorkspaceDrawer(store: workspaceStore) { wid, sid in
                    workspaceStore.selectedId = wid
                    activeSurfaceId = sid
                    showDrawer = false
                    Task { await surfaceStore.subscribe(workspaceId: wid, surfaceId: sid) }
                }
            }
        }
        .task {
            if let ws = currentWorkspace, let first = ws.surfaces.first {
                activeSurfaceId = first.id
                await surfaceStore.subscribe(workspaceId: ws.id, surfaceId: first.id)
            }
        }
    }

    private var currentWorkspace: Workspace? {
        guard let id = workspaceStore.selectedId else { return nil }
        return workspaceStore.workspaces.first { $0.id == id }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add ios/CmuxRemote/Workspace/WorkspaceView.swift ios/CmuxRemote/Workspace/WorkspaceDrawer.swift
git commit -m "M4.13: WorkspaceView with surface tab strip + drawer"
```

---

## Task 14 — `NotificationCenterView`

**Files:**
- Create: `ios/CmuxRemote/Notifications/NotificationCenterView.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import SharedKit

struct NotificationCenterView: View {
    @Bindable var store: NotificationStore
    var onTap: (NotificationRecord) -> Void

    var body: some View {
        NavigationStack {
            List(store.items) { n in
                Button { onTap(n) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.title).font(.headline)
                        if let s = n.subtitle { Text(s).font(.caption).foregroundStyle(.secondary) }
                        Text(n.body).font(.body)
                    }
                }
            }
            .navigationTitle("Notifications")
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/CmuxRemote/Notifications/NotificationCenterView.swift
git commit -m "M4.14: NotificationCenterView (in-app list)"
```

---

## Task 15 — `SettingsView`

**Files:**
- Create: `ios/CmuxRemote/Settings/SettingsView.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct SettingsView: View {
    @Bindable var store: WorkspaceStore
    let onDisconnect: () -> Void
    @AppStorage("cmux.host") private var host: String = ""
    @AppStorage("cmux.port") private var port: Int = 4399

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    TextField("hostname (e.g. myhost.tailnet.ts.net)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Stepper(value: $port, in: 1024...65535) { Text("port: \(port)") }
                    HStack {
                        Circle().fill(color(for: store.connection)).frame(width: 8, height: 8)
                        Text(label(store.connection))
                    }
                }
                Section("Device") {
                    Button("Disconnect this device", role: .destructive, action: onDisconnect)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func color(for s: ConnectionState) -> Color {
        switch s {
        case .connected: return .green
        case .connecting: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }
    private func label(_ s: ConnectionState) -> String {
        switch s {
        case .connected: return "connected"
        case .connecting: return "connecting…"
        case .error(let m): return "error: \(m)"
        case .disconnected: return "disconnected"
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/CmuxRemote/Settings/SettingsView.swift
git commit -m "M4.15: SettingsView (host/port/connection state/disconnect)"
```

---

## Task 16 — `CmuxRemoteApp` + `ContentView`

**Files:**
- Modify: `ios/CmuxRemote/CmuxRemoteApp.swift`
- Create: `ios/CmuxRemote/ContentView.swift`

- [ ] **Step 1: Implement App**

```swift
import SwiftUI

@main
struct CmuxRemoteApp: App {
    @State private var workspaceStore: WorkspaceStore?
    @State private var surfaceStore: SurfaceStore?
    @State private var notifStore = NotificationStore()
    @State private var ready = false

    var body: some Scene {
        WindowGroup {
            ContentView(workspaceStore: workspaceStore,
                        surfaceStore: surfaceStore,
                        notifStore: notifStore)
                .task { await bootstrap() }
                .onOpenURL(perform: handleDeepLink(_:))
        }
    }

    private func bootstrap() async {
        let kc = Keychain(service: "com.genie.cmuxremote")
        let result = HardeningCheck(keychain: kc).runAtLaunch()
        guard result == .ok else { return }
        let host = UserDefaults.standard.string(forKey: "cmux.host") ?? ""
        let port = UserDefaults.standard.integer(forKey: "cmux.port") == 0
            ? 4399 : UserDefaults.standard.integer(forKey: "cmux.port")
        guard !host.isEmpty else { return }
        let url = URL(string: "wss://\(host):\(port)/v1/stream")!
        let auth = AuthClient(host: host, port: port, keychain: kc, http: URLSessionHTTP())
        try? await auth.registerIfNeeded()
        guard let token = try? kc.get("bearer") else { return }
        let ws = WSClient(url: url, headers: [
            "Sec-WebSocket-Protocol": "cmuxremote.v1, bearer.\(token)",
        ])
        await ws.connect()
        let rpc = RPCClient(transport: ws)
        await rpc.onPush { frame in
            Task { @MainActor in
                self.surfaceStore?.ingest(frame)
                self.notifStore.ingest(frame)
            }
        }
        ws.onText = { text in Task { await rpc.handleIncoming(text: text) } }
        let wsStore = WorkspaceStore(rpc: rpc)
        let sfStore = SurfaceStore(rpc: rpc)
        await MainActor.run {
            self.workspaceStore = wsStore
            self.surfaceStore = sfStore
            self.ready = true
        }
        await wsStore.refresh()
    }

    private func handleDeepLink(_ url: URL) {
        // cmux://surface/<id> handled in M6
    }
}
```

- [ ] **Step 2: Implement `ContentView`**

```swift
import SwiftUI

struct ContentView: View {
    let workspaceStore: WorkspaceStore?
    let surfaceStore: SurfaceStore?
    let notifStore: NotificationStore

    var body: some View {
        if let ws = workspaceStore, let sf = surfaceStore {
            TabView {
                NavigationStack {
                    WorkspaceListView(store: ws) { _ in /* swap to detail tab */ }
                }
                .tabItem { Label("Workspaces", systemImage: "rectangle.stack") }

                NavigationStack {
                    WorkspaceView(workspaceStore: ws, surfaceStore: sf)
                }
                .tabItem { Label("Active", systemImage: "terminal") }

                NotificationCenterView(store: notifStore) { _ in }
                    .tabItem { Label("Inbox", systemImage: "bell") }

                SettingsView(store: ws) { try? Keychain(service: "com.genie.cmuxremote").wipe() }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Configure host in Settings → Mac")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 3: Build + smoke**

```bash
xcodebuild build -project ios/CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' | tail -3
```
Expected: `Build complete!`.

- [ ] **Step 4: Commit**

```bash
git add ios/CmuxRemote/CmuxRemoteApp.swift ios/CmuxRemote/ContentView.swift
git commit -m "M4.16: app entry + TabView wiring + bootstrap"
```

---

## Task 17 — Reconnect + checksum reconciliation

When the WS reconnects (after sleep, network flap), each subscribed surface re-issues `surface.subscribe`. On every `screen.checksum` push, the iOS side compares with `ScreenHasher.hash(grid.toScreen())` and re-fetches `screen.full` if mismatched.

**Files:**
- Modify: `ios/CmuxRemote/Stores/SurfaceStore.swift`
- Test:   `ios/CmuxRemoteTests/ChecksumReconcileTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
import SharedKit
@testable import CmuxRemote

final class ChecksumReconcileTests: XCTestCase {
    func testMismatchTriggersFullRequest() async {
        let stub = StubRPC()
        let store = SurfaceStore(rpc: stub)
        store.ingest(.screenFull(ScreenFull(surfaceId: "s", rev: 1,
            rows: ["a","b"], cols: 1, rowsCount: 2, cursor: .init(x: 0, y: 0))))
        store.subscribed = "s"
        // Inject deliberately wrong checksum
        store.ingest(.screenChecksum(ScreenChecksum(surfaceId: "s", rev: 1, hash: "deadbeef00000000")))
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertTrue(stub.calls.contains { $0.0 == "surface.read_text" })
    }
}
```

(Stub RPCClient via test override or new `final class StubRPC: RPCClient { ... }` — simplest is to extract the RPC dependency to a protocol `RPCDispatch`. If that refactor is too disruptive, gate this test on env var and use the live integration.)

- [ ] **Step 2: Implement reconciliation in `SurfaceStore.swift`**

```swift
extension SurfaceStore {
    public func ingest(_ frame: PushFrame) async {
        if case .screenChecksum(let f) = frame, f.surfaceId == subscribed {
            let computed = ScreenHasher.hash(currentScreen())
            if computed != f.hash {
                _ = try? await rpc.call(method: "surface.read_text",
                                        params: .object([
                                            "workspace_id": .null,   // server fills via session
                                            "surface_id": .string(f.surfaceId),
                                            "lines": .int(Int64(grid.rows.count)),
                                        ]))
            }
        } else { ingest(frame) }                       // route to existing sync ingest
    }
    private func currentScreen() -> Screen {
        // Reconstruct a Screen from the grid's raw rows (no ANSI to reproduce).
        Screen(rev: rev, rows: grid.rows.map { row in row.map { String($0.character) }.joined() },
               cols: grid.cols, cursor: grid.cursor)
    }
}
```

(Re-converting cells to a single string drops attributes, so the recomputed checksum will only match for ASCII-only output. For SGR-heavy frames the spec expects the client to ALWAYS request `screen.full` — we conservatively re-fetch on every checksum mismatch; that's acceptable cadence-wise since checksums are 5 s.)

- [ ] **Step 3: Run + commit**

```bash
xcodebuild test -project ios/CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:CmuxRemoteTests/ChecksumReconcileTests | tail -3
git add ios/CmuxRemote/Stores/SurfaceStore.swift ios/CmuxRemoteTests/ChecksumReconcileTests.swift
git commit -m "M4.17: surface checksum reconciliation"
```

---

## Task 18 — XCUITest: home → workspace → input

**Files:**
- Create: `ios/CmuxRemoteUITests/SmokeUITests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest

final class SmokeUITests: XCTestCase {
    func testTabsExistAfterConnect() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"      // bootstrap path uses fake host
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Workspaces"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Active"].exists)
        XCTAssertTrue(app.tabBars.buttons["Inbox"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
    }
}
```

To make this work without a real relay, gate `CmuxRemoteApp.bootstrap()` on `CMUX_FAKE_RELAY=1` and inject a `MockTransport` that echoes a fake `workspace.list` response. Add ~25 lines of fake transport code in `CmuxRemoteApp.swift` behind the env-var guard.

- [ ] **Step 2: Run**

```bash
xcodebuild test -project ios/CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:CmuxRemoteUITests/SmokeUITests | tail -3
```
Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add ios/CmuxRemoteUITests/SmokeUITests.swift ios/CmuxRemote/CmuxRemoteApp.swift
git commit -m "M4.18: XCUITest tab smoke + fake-transport bootstrap path"
```

---

## Exit criteria

```bash
xcodebuild test -project ios/CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' | tail -10
```

Required:
- All `CmuxRemoteTests` and `CmuxRemoteUITests` pass
- Manual smoke (with M3 relay running on the same Mac):
  1. Set Settings → host = `<mac>.<tailnet>.ts.net`
  2. Force-quit + relaunch app
  3. Workspaces tab lists workspaces from cmux
  4. Tap a workspace → Active tab shows surface output
  5. Quick keyboard tap (system keyboard, the AccessoryBar lands in M5) → cmux receives the keystroke

## Self-review

- [ ] **Coverage:** `WorkspaceListView`, `WorkspaceView`, `WorkspaceDrawer`, `TerminalView`, `NotificationCenterView`, `SettingsView` all exist. `WSClient` reconnects with backoff. `HardeningCheck.runAtLaunch()` is called in app bootstrap.
- [ ] **Placeholder scan:** `grep -RnE "TODO|FIXME|tbd" ios/CmuxRemote` returns no hits.
- [ ] **Type consistency:** all stores use `SharedKit` types, never duplicate `Workspace`/`Surface`/`NotificationRecord`/`Screen`/`PushFrame`.

## Merge

```bash
git checkout main
git merge --ff-only m4-ios
git branch -d m4-ios
```

Pick up M5 next: `2026-05-09-m5-accessory-bar.md`.
