# M1 — Repo Bootstrap + SharedKit

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Swift package, the iOS-and-Mac-shared `SharedKit` module (Codable wire types, DiffOp, KeyEncoder), and the test harness so every later milestone has a typed contract to point at.

**Architecture:** Pure-data Swift module. No I/O, no concurrency primitives, no Foundation networking — only `Foundation` `Data`/`Date`/`UUID` + `swift-testing`. Targets macOS 13+ / iOS 17+ so the same artifact links into both the relay and the iOS app.

**Tech Stack:** Swift 5.10, `swift-testing`, no third-party deps.

**Branch:** `m1-sharedkit` from `main`.

---

## Spec coverage

- Spec section 3 ("High-level architecture") — establishes the unit boundary.
- Spec section 4 ("Project layout") — task 1 creates Package.swift + dirs.
- Spec section 5 ("External dependencies") — task 1 declares the deps used later.
- Spec section 6.2 ("JSON-RPC envelope") — task 2.
- Spec section 6.4 ("DiffEngine") — `DiffOp` type lives here; engine itself in M2.
- Spec section 6.5 ("Input") — `KeyEncoder` table.
- Spec section 11 ("Test strategy") — `swift-testing` + round-trip tests.

## File map for this milestone

Create:

- `Package.swift`
- `.gitignore`
- `README.md`
- `Sources/SharedKit/JSONRPC.swift`
- `Sources/SharedKit/Models.swift`
- `Sources/SharedKit/DiffOp.swift`
- `Sources/SharedKit/Screen.swift`
- `Sources/SharedKit/KeyEncoder.swift`
- `Sources/SharedKit/WireProtocol.swift`
- `Tests/SharedKitTests/JSONRPCTests.swift`
- `Tests/SharedKitTests/ModelsTests.swift`
- `Tests/SharedKitTests/DiffOpTests.swift`
- `Tests/SharedKitTests/KeyEncoderTests.swift`
- `Tests/SharedKitTests/WireProtocolTests.swift`

Modify (later milestones touch the rest of `Sources/...`; in M1 we only stub them by creating empty target dirs):

- `Sources/CMUXClient/.gitkeep`
- `Sources/RelayCore/.gitkeep`
- `Sources/RelayServer/.gitkeep`

---

## Task 1 — Branch + Package scaffolding

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `README.md`
- Create: `Sources/SharedKit/.gitkeep`
- Create: `Sources/CMUXClient/.gitkeep`
- Create: `Sources/RelayCore/.gitkeep`
- Create: `Sources/RelayServer/.gitkeep`
- Create: `Tests/SharedKitTests/.gitkeep`

- [ ] **Step 1: Create branch from main**

```bash
git checkout main
git pull --ff-only || true   # no remote yet, fine if it noops
git checkout -b m1-sharedkit
```

- [ ] **Step 2: Write `Package.swift`**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CmuxRemote",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SharedKit", targets: ["SharedKit"]),
        .library(name: "CMUXClient", targets: ["CMUXClient"]),
        .library(name: "RelayCore",  targets: ["RelayCore"]),
        .executable(name: "cmux-relay", targets: ["RelayServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git",            from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git",        from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-log.git",            from: "1.5.4"),
        .package(url: "https://github.com/apple/swift-argument-parser",    from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git",         from: "3.4.0"),
        .package(url: "https://github.com/swift-server/async-http-client", from: "1.21.0"),
    ],
    targets: [
        .target(name: "SharedKit"),
        .target(
            name: "CMUXClient",
            dependencies: [
                "SharedKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "RelayCore",
            dependencies: [
                "SharedKit",
                "CMUXClient",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "RelayServer",
            dependencies: [
                "RelayCore",
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "SharedKitTests",  dependencies: ["SharedKit"]),
        .testTarget(name: "CMUXClientTests", dependencies: ["CMUXClient"]),
        .testTarget(name: "DiffEngineTests", dependencies: ["RelayCore"]),
        .testTarget(name: "RelayCoreTests",  dependencies: ["RelayCore"]),
    ]
)
```

The `tsnet`/`libtailscale` and `IOSSecuritySuite` deps are added in their respective milestones (M3, M4) to keep M1 buildable without C dependencies.

- [ ] **Step 3: Write `.gitignore`**

```
.build/
.swiftpm/
DerivedData/
*.xcodeproj/xcuserdata/
*.xcworkspace/xcuserdata/
ios/CmuxRemote.xcodeproj/project.xcworkspace/xcuserdata/
ios/CmuxRemote.xcodeproj/xcuserdata/
.DS_Store
*.xcuserstate
Package.resolved
```

- [ ] **Step 4: Stub `README.md`**

```markdown
# cmux-iphone-bridge

iPhone-only client for cmux on Mac, over Tailscale. v1.0 design spec: `docs/specs/2026-05-09-cmux-iphone-bridge-design.md`. Milestone plans: `docs/superpowers/plans/2026-05-09-*`.
```

- [ ] **Step 5: Create empty target dirs and tests dir**

```bash
mkdir -p Sources/SharedKit Sources/CMUXClient Sources/RelayCore Sources/RelayServer
mkdir -p Tests/SharedKitTests Tests/CMUXClientTests Tests/DiffEngineTests Tests/RelayCoreTests
touch Sources/CMUXClient/.gitkeep Sources/RelayCore/.gitkeep Sources/RelayServer/.gitkeep
touch Tests/CMUXClientTests/.gitkeep Tests/DiffEngineTests/.gitkeep Tests/RelayCoreTests/.gitkeep
```

The `.gitkeep` files prevent empty target build errors only after we add a real source — in M1 the SharedKit dir gets real files immediately. CMUXClient/RelayCore/RelayServer remain empty (with the keep file) until their milestones; SwiftPM 5.10 tolerates a target with only a `.gitkeep` *if at least one source-bearing target exists*, but to be safe we comment those targets out until their milestone activates them.

- [ ] **Step 6: Comment out un-implemented targets in `Package.swift`**

Edit `Package.swift` and wrap the four un-implemented targets (`CMUXClient`, `RelayCore`, `RelayServer` execs and the three later test targets) with `// MILESTONE-GATED`. Replace the targets array with:

```swift
    targets: [
        .target(name: "SharedKit"),
        .testTarget(name: "SharedKitTests", dependencies: ["SharedKit"]),
        // MILESTONE-GATED: re-enable in M2/M3
        // .target(name: "CMUXClient", ...),
        // .target(name: "RelayCore", ...),
        // .executableTarget(name: "RelayServer", ...),
        // .testTarget(name: "CMUXClientTests", dependencies: ["CMUXClient"]),
        // .testTarget(name: "DiffEngineTests", dependencies: ["RelayCore"]),
        // .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
    ]
```

Likewise, drop the four un-built products from the `products:` array in M1; we re-add them when their target activates.

- [ ] **Step 7: Verify package resolves**

Run: `swift build`
Expected: `Build complete!` (no SharedKit code yet, but `swift build` succeeds because SharedKit target is empty-but-allowed; if SwiftPM rejects the empty target, drop a one-line `Sources/SharedKit/Package.swift.placeholder.swift` containing `// placeholder` — task 2 replaces it immediately.)

- [ ] **Step 8: Commit**

```bash
git add Package.swift .gitignore README.md Sources Tests
git commit -m "M1.1: scaffold Swift package + dirs"
```

---

## Task 2 — JSON-RPC envelope (`JSONRPC.swift`)

Spec section 6.2.

**Files:**
- Create: `Sources/SharedKit/JSONRPC.swift`
- Test:   `Tests/SharedKitTests/JSONRPCTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/SharedKitTests/JSONRPCTests.swift`:

```swift
import Testing
import Foundation
@testable import SharedKit

@Suite("JSON-RPC envelope")
struct JSONRPCTests {
    @Test func requestEncodesWithIdMethodParams() throws {
        let req = RPCRequest(id: 1, method: "workspace.list", params: .object([:]))
        let data = try JSONEncoder().encode(req)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"method\":\"workspace.list\""))
        #expect(json.contains("\"id\":1"))
    }

    @Test func okResponseDecodes() throws {
        let raw = #"{"id":1,"ok":true,"result":{"workspaces":[]}}"#
        let resp = try JSONDecoder().decode(RPCResponse.self, from: Data(raw.utf8))
        #expect(resp.id == 1)
        #expect(resp.ok == true)
        #expect(resp.error == nil)
    }

    @Test func errorResponseDecodes() throws {
        let raw = #"{"id":2,"ok":false,"error":{"code":-32000,"message":"boom"}}"#
        let resp = try JSONDecoder().decode(RPCResponse.self, from: Data(raw.utf8))
        #expect(resp.ok == false)
        #expect(resp.error?.code == -32000)
        #expect(resp.error?.message == "boom")
    }

    @Test func paramsAcceptArbitraryShape() throws {
        let raw = #"{"id":7,"method":"events.subscribe","params":{"categories":["notification"]}}"#
        let req = try JSONDecoder().decode(RPCRequest.self, from: Data(raw.utf8))
        #expect(req.method == "events.subscribe")
        if case .object(let dict) = req.params,
           case .array(let arr) = dict["categories"],
           case .string(let s)  = arr.first {
            #expect(s == "notification")
        } else {
            Issue.record("params shape not parsed")
        }
    }
}
```

- [ ] **Step 2: Run — expect compile failure**

Run: `swift test --filter SharedKitTests.JSONRPCTests`
Expected: FAIL (`RPCRequest` / `RPCResponse` / `JSONValue` undefined).

- [ ] **Step 3: Implement `JSONRPC.swift`**

```swift
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
    public var id: Int64
    public var method: String
    public var params: JSONValue
    public init(id: Int64, method: String, params: JSONValue) {
        self.id = id; self.method = method; self.params = params
    }
}

public struct RPCError: Codable, Sendable, Equatable {
    public var code: Int
    public var message: String
    public var data: JSONValue?
    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code; self.message = message; self.data = data
    }
}

public struct RPCResponse: Codable, Sendable, Equatable {
    public var id: Int64
    public var ok: Bool
    public var result: JSONValue?
    public var error: RPCError?
    public init(id: Int64, ok: Bool, result: JSONValue? = nil, error: RPCError? = nil) {
        self.id = id; self.ok = ok; self.result = result; self.error = error
    }
}
```

- [ ] **Step 4: Run — expect green**

Run: `swift test --filter SharedKitTests.JSONRPCTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SharedKit/JSONRPC.swift Tests/SharedKitTests/JSONRPCTests.swift
git commit -m "M1.2: JSON-RPC envelope + JSONValue (SharedKit)"
```

---

## Task 3 — Domain models (`Models.swift`)

Spec sections 6.3, 9.1.

**Files:**
- Create: `Sources/SharedKit/Models.swift`
- Test:   `Tests/SharedKitTests/ModelsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import SharedKit

@Suite("Models")
struct ModelsTests {
    @Test func workspaceRoundTrip() throws {
        let ws = Workspace(id: "ws-1", name: "frontend", surfaces: [
            Surface(id: "sf-1", title: "shell", cols: 120, rows: 30, lastActivity: 1000),
        ], lastActivity: 2000)
        let data = try JSONEncoder().encode(ws)
        let back = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(back == ws)
    }

    @Test func notificationRoundTrip() throws {
        let n = NotificationRecord(
            id: "n-1", workspaceId: "ws-1", surfaceId: "sf-1",
            title: "Build done", subtitle: "ws/frontend", body: "✅ tests green",
            ts: 1714000000, threadId: "ws-ws-1"
        )
        let data = try JSONEncoder().encode(n)
        let back = try JSONDecoder().decode(NotificationRecord.self, from: data)
        #expect(back == n)
    }

    @Test func bootInfoRoundTrip() throws {
        let b = BootInfo(bootId: "b-7", startedAt: 1714000000)
        let data = try JSONEncoder().encode(b)
        let back = try JSONDecoder().decode(BootInfo.self, from: data)
        #expect(back == b)
    }
}
```

- [ ] **Step 2: Run — expect failure (types undefined)**

Run: `swift test --filter SharedKitTests.ModelsTests`
Expected: FAIL.

- [ ] **Step 3: Implement `Models.swift`**

```swift
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
```

- [ ] **Step 4: Run — expect green**

Run: `swift test --filter SharedKitTests.ModelsTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SharedKit/Models.swift Tests/SharedKitTests/ModelsTests.swift
git commit -m "M1.3: domain models (Workspace, Surface, NotificationRecord, BootInfo)"
```

---

## Task 4 — Screen + DiffOp (`Screen.swift`, `DiffOp.swift`)

Spec section 6.4. Per spec, "DiffOp.apply is inverse of compute" — both live in SharedKit and operate on a row-array snapshot. ANSI parsing is *not* done here; rows are opaque ANSI strings. The viewer (iOS) interprets SGR escapes downstream.

**Files:**
- Create: `Sources/SharedKit/Screen.swift`
- Create: `Sources/SharedKit/DiffOp.swift`
- Test:   `Tests/SharedKitTests/DiffOpTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import SharedKit

@Suite("DiffOp")
struct DiffOpTests {
    @Test func emptyDiffWhenScreensEqual() {
        let a = Screen(rev: 0, rows: ["one", "two"], cols: 3, cursor: .init(x: 0, y: 0))
        let b = a
        #expect(DiffOp.compute(from: a, to: b) == [])
    }

    @Test func rowDiffPerLine() {
        let a = Screen(rev: 1, rows: ["one", "two", "three"], cols: 5, cursor: .init(x: 0, y: 0))
        var b = a
        b.rows[1] = "TWO"
        b.rev = 2
        let ops = DiffOp.compute(from: a, to: b)
        #expect(ops == [.row(y: 1, text: "TWO")])
    }

    @Test func cursorOnlyDiff() {
        let a = Screen(rev: 1, rows: ["x"], cols: 1, cursor: .init(x: 0, y: 0))
        var b = a
        b.cursor = .init(x: 5, y: 9)
        b.rev = 2
        let ops = DiffOp.compute(from: a, to: b)
        #expect(ops == [.cursor(x: 5, y: 9)])
    }

    @Test func applyIsInverseOfCompute() {
        let a = Screen(rev: 1,
                       rows: ["alpha", "beta", "gamma"],
                       cols: 5,
                       cursor: .init(x: 1, y: 1))
        var b = a
        b.rows[0] = "ALPHA"
        b.rows[2] = "GAMMA"
        b.cursor = .init(x: 4, y: 2)
        b.rev    = 2
        let ops = DiffOp.compute(from: a, to: b)
        var reconstructed = a
        DiffOp.apply(ops, to: &reconstructed)
        reconstructed.rev = b.rev   // rev is metadata; not transported in DiffOp
        #expect(reconstructed == b)
    }

    @Test func diffOpEncodesRowVariant() throws {
        let op: DiffOp = .row(y: 7, text: "$ ls")
        let json = try String(data: JSONEncoder().encode(op), encoding: .utf8)!
        #expect(json.contains("\"op\":\"row\""))
        #expect(json.contains("\"y\":7"))
        #expect(json.contains("\"text\":\"$ ls\""))
    }

    @Test func diffOpEncodesCursorVariant() throws {
        let op: DiffOp = .cursor(x: 0, y: 9)
        let json = try String(data: JSONEncoder().encode(op), encoding: .utf8)!
        #expect(json.contains("\"op\":\"cursor\""))
        #expect(json.contains("\"x\":0"))
        #expect(json.contains("\"y\":9"))
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter SharedKitTests.DiffOpTests`
Expected: FAIL.

- [ ] **Step 3: Implement `Screen.swift`**

```swift
import Foundation

public struct CursorPos: Codable, Sendable, Equatable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public struct Screen: Codable, Sendable, Equatable {
    public var rev: Int
    public var rows: [String]   // raw ANSI lines, viewer-side parsing
    public var cols: Int
    public var cursor: CursorPos
    public init(rev: Int, rows: [String], cols: Int, cursor: CursorPos) {
        self.rev = rev; self.rows = rows; self.cols = cols; self.cursor = cursor
    }
}
```

- [ ] **Step 4: Implement `DiffOp.swift`**

```swift
import Foundation

public enum DiffOp: Codable, Sendable, Equatable {
    case row(y: Int, text: String)
    case cursor(x: Int, y: Int)
    case clear

    private enum CodingKeys: String, CodingKey { case op, y, x, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .op) {
        case "row":    self = .row(y: try c.decode(Int.self, forKey: .y),
                                   text: try c.decode(String.self, forKey: .text))
        case "cursor": self = .cursor(x: try c.decode(Int.self, forKey: .x),
                                      y: try c.decode(Int.self, forKey: .y))
        case "clear":  self = .clear
        case let other: throw DecodingError.dataCorruptedError(
            forKey: .op, in: c, debugDescription: "Unknown op: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .row(let y, let text):
            try c.encode("row",    forKey: .op)
            try c.encode(y,        forKey: .y)
            try c.encode(text,     forKey: .text)
        case .cursor(let x, let y):
            try c.encode("cursor", forKey: .op)
            try c.encode(x,        forKey: .x)
            try c.encode(y,        forKey: .y)
        case .clear:
            try c.encode("clear",  forKey: .op)
        }
    }

    /// Compute the minimal set of ops that transforms `from` into `to`.
    /// Row count mismatches emit a `.clear` followed by full row replacements.
    public static func compute(from old: Screen, to new: Screen) -> [DiffOp] {
        var ops: [DiffOp] = []
        if old.rows.count != new.rows.count {
            ops.append(.clear)
            for (i, row) in new.rows.enumerated() { ops.append(.row(y: i, text: row)) }
        } else {
            for i in 0..<new.rows.count where old.rows[i] != new.rows[i] {
                ops.append(.row(y: i, text: new.rows[i]))
            }
        }
        if old.cursor != new.cursor {
            ops.append(.cursor(x: new.cursor.x, y: new.cursor.y))
        }
        return ops
    }

    /// Apply ops in order, mutating `screen` to match the source side's `new`.
    public static func apply(_ ops: [DiffOp], to screen: inout Screen) {
        for op in ops {
            switch op {
            case .clear:
                screen.rows = Array(repeating: "", count: screen.rows.count)
            case .row(let y, let text):
                if y >= screen.rows.count {
                    screen.rows.append(contentsOf: Array(repeating: "", count: y - screen.rows.count + 1))
                }
                screen.rows[y] = text
            case .cursor(let x, let y):
                screen.cursor = CursorPos(x: x, y: y)
            }
        }
    }
}
```

- [ ] **Step 5: Run — expect green**

Run: `swift test --filter SharedKitTests.DiffOpTests`
Expected: 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/SharedKit/Screen.swift Sources/SharedKit/DiffOp.swift Tests/SharedKitTests/DiffOpTests.swift
git commit -m "M1.4: Screen + DiffOp compute/apply round-trip"
```

---

## Task 5 — KeyEncoder (`KeyEncoder.swift`)

Spec section 6.5. Cmux's existing key vocabulary is a fixed string set (`enter`, `tab`, `up`, `ctrl+c`, `esc`, …). The encoder normalizes UI keystrokes into that vocabulary.

**Files:**
- Create: `Sources/SharedKit/KeyEncoder.swift`
- Test:   `Tests/SharedKitTests/KeyEncoderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SharedKit

@Suite("KeyEncoder")
struct KeyEncoderTests {
    @Test func plainKeysAreNormalized() {
        #expect(KeyEncoder.encode(.enter) == "enter")
        #expect(KeyEncoder.encode(.tab)   == "tab")
        #expect(KeyEncoder.encode(.up)    == "up")
        #expect(KeyEncoder.encode(.esc)   == "esc")
    }

    @Test func modifiersAreLowerCasePlusJoined() {
        #expect(KeyEncoder.encode(.named("c", modifiers: [.ctrl]))           == "ctrl+c")
        #expect(KeyEncoder.encode(.named("c", modifiers: [.ctrl, .shift]))   == "ctrl+shift+c")
        #expect(KeyEncoder.encode(.named("[", modifiers: [.alt]))            == "alt+[")
    }

    @Test func directionWithModifier() {
        #expect(KeyEncoder.encode(.named("up", modifiers: [.shift])) == "shift+up")
    }

    @Test func parseRoundTripForKnown() throws {
        let encoded = "ctrl+shift+c"
        let key = try #require(KeyEncoder.decode(encoded))
        #expect(KeyEncoder.encode(key) == encoded)
    }

    @Test func parseRejectsEmpty() {
        #expect(KeyEncoder.decode("") == nil)
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter SharedKitTests.KeyEncoderTests`
Expected: FAIL.

- [ ] **Step 3: Implement `KeyEncoder.swift`**

```swift
import Foundation

public enum KeyModifier: String, Codable, Sendable, CaseIterable {
    case ctrl, alt, shift, cmd
    public static let canonicalOrder: [KeyModifier] = [.ctrl, .alt, .shift, .cmd]
}

public enum Key: Sendable, Equatable {
    case enter, tab, esc, up, down, left, right, home, end, pageUp, pageDown, backspace, delete
    case named(String, modifiers: Set<KeyModifier>)

    fileprivate var rawName: String {
        switch self {
        case .enter:     return "enter"
        case .tab:       return "tab"
        case .esc:       return "esc"
        case .up:        return "up"
        case .down:      return "down"
        case .left:      return "left"
        case .right:     return "right"
        case .home:      return "home"
        case .end:       return "end"
        case .pageUp:    return "pgup"
        case .pageDown:  return "pgdn"
        case .backspace: return "backspace"
        case .delete:    return "delete"
        case .named(let n, _): return n
        }
    }

    fileprivate var modifiers: Set<KeyModifier> {
        if case .named(_, let m) = self { return m }
        return []
    }
}

public enum KeyEncoder {
    public static func encode(_ key: Key) -> String {
        let mods = KeyModifier.canonicalOrder.filter { key.modifiers.contains($0) }
        let prefix = mods.map(\.rawValue).joined(separator: "+")
        let name = key.rawName
        return prefix.isEmpty ? name : "\(prefix)+\(name)"
    }

    public static func decode(_ s: String) -> Key? {
        guard !s.isEmpty else { return nil }
        var parts = s.split(separator: "+").map(String.init)
        guard !parts.isEmpty else { return nil }
        let name = parts.removeLast()
        var mods: Set<KeyModifier> = []
        for p in parts {
            guard let m = KeyModifier(rawValue: p) else { return nil }
            mods.insert(m)
        }
        if mods.isEmpty {
            switch name {
            case "enter": return .enter
            case "tab":   return .tab
            case "esc":   return .esc
            case "up":    return .up
            case "down":  return .down
            case "left":  return .left
            case "right": return .right
            case "home":  return .home
            case "end":   return .end
            case "pgup":  return .pageUp
            case "pgdn":  return .pageDown
            case "backspace": return .backspace
            case "delete":    return .delete
            default:      return .named(name, modifiers: [])
            }
        }
        return .named(name, modifiers: mods)
    }
}
```

- [ ] **Step 4: Run — expect green**

Run: `swift test --filter SharedKitTests.KeyEncoderTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SharedKit/KeyEncoder.swift Tests/SharedKitTests/KeyEncoderTests.swift
git commit -m "M1.5: Key + KeyEncoder canonical encode/decode"
```

---

## Task 6 — Wire-protocol push frames (`WireProtocol.swift`)

Spec section 6.2 (server → client push frames) and 6.3 (`event`). These are server-pushed frames *without* an `id`, so they need a discriminated-union type distinct from `RPCResponse`.

**Files:**
- Create: `Sources/SharedKit/WireProtocol.swift`
- Test:   `Tests/SharedKitTests/WireProtocolTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import SharedKit

@Suite("WireProtocol")
struct WireProtocolTests {
    @Test func screenFullDecodes() throws {
        let raw = """
        {"type":"screen.full","surface_id":"sf","rev":0,"rows":["a","b"],"cols":2,"rowsCount":2,"cursor":{"x":0,"y":0}}
        """
        let frame = try JSONDecoder().decode(PushFrame.self, from: Data(raw.utf8))
        guard case .screenFull(let f) = frame else { Issue.record("not screen.full"); return }
        #expect(f.surfaceId == "sf")
        #expect(f.rev == 0)
        #expect(f.rows == ["a","b"])
        #expect(f.cursor.x == 0)
    }

    @Test func screenDiffDecodes() throws {
        let raw = """
        {"type":"screen.diff","surface_id":"sf","rev":42,
         "ops":[{"op":"row","y":7,"text":"$ ls"},{"op":"cursor","x":0,"y":9}]}
        """
        let frame = try JSONDecoder().decode(PushFrame.self, from: Data(raw.utf8))
        guard case .screenDiff(let f) = frame else { Issue.record("not screen.diff"); return }
        #expect(f.surfaceId == "sf")
        #expect(f.rev == 42)
        #expect(f.ops.count == 2)
    }

    @Test func screenChecksumDecodes() throws {
        let raw = #"{"type":"screen.checksum","surface_id":"sf","rev":42,"hash":"abc"}"#
        let frame = try JSONDecoder().decode(PushFrame.self, from: Data(raw.utf8))
        guard case .screenChecksum(let f) = frame else { Issue.record("wrong"); return }
        #expect(f.hash == "abc")
    }

    @Test func eventFrameDecodes() throws {
        let raw = """
        {"type":"event","category":"notification","name":"notification.created","payload":{"foo":"bar"}}
        """
        let frame = try JSONDecoder().decode(PushFrame.self, from: Data(raw.utf8))
        guard case .event(let f) = frame else { Issue.record("wrong"); return }
        #expect(f.category == .notification)
        #expect(f.name == "notification.created")
    }

    @Test func pingPongDecodes() throws {
        let ping = try JSONDecoder().decode(PushFrame.self, from: Data(#"{"type":"ping","ts":42}"#.utf8))
        guard case .ping(let p) = ping else { Issue.record("wrong"); return }
        #expect(p.ts == 42)
    }

    @Test func helloFrameRoundTrip() throws {
        let h = HelloFrame(deviceId: "dev-1", appVersion: "1.0.0", protocolVersion: 1)
        let data = try JSONEncoder().encode(h)
        let back = try JSONDecoder().decode(HelloFrame.self, from: data)
        #expect(back == h)
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter SharedKitTests.WireProtocolTests`
Expected: FAIL.

- [ ] **Step 3: Implement `WireProtocol.swift`**

```swift
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
```

- [ ] **Step 4: Run — expect green**

Run: `swift test --filter SharedKitTests.WireProtocolTests`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SharedKit/WireProtocol.swift Tests/SharedKitTests/WireProtocolTests.swift
git commit -m "M1.6: WireProtocol push frames + HelloFrame"
```

---

## Task 7 — Encoder/decoder helpers (snake-case, deterministic)

Many JSON-RPC clients in this stack will need consistent JSON encoding (sorted keys for golden fixtures in M2; snake-case where the wire spec uses snake-case). Add convenience encoders so callers don't reinvent each time.

**Files:**
- Create: `Sources/SharedKit/JSONCoders.swift`
- Modify: `Sources/SharedKit/JSONRPC.swift` — none. (helper is additive.)
- Test:   add `Tests/SharedKitTests/JSONCodersTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import SharedKit

@Suite("JSONCoders")
struct JSONCodersTests {
    @Test func deterministicEncoderProducesSortedKeys() throws {
        struct T: Codable { let z: Int; let a: Int }
        let data = try SharedKitJSON.deterministicEncoder.encode(T(z: 2, a: 1))
        let s = String(data: data, encoding: .utf8)!
        #expect(s == #"{"a":1,"z":2}"#)
    }

    @Test func snakeCaseEncoderConvertsCamel() throws {
        struct T: Codable { let surfaceId: String }
        let data = try SharedKitJSON.snakeCaseEncoder.encode(T(surfaceId: "x"))
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("surface_id"))
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter SharedKitTests.JSONCodersTests`
Expected: FAIL.

- [ ] **Step 3: Implement `JSONCoders.swift`**

```swift
import Foundation

public enum SharedKitJSON {
    public static var deterministicEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
    public static var snakeCaseEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }
    public static var snakeCaseDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}
```

- [ ] **Step 4: Run — expect green**

Run: `swift test --filter SharedKitTests.JSONCodersTests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SharedKit/JSONCoders.swift Tests/SharedKitTests/JSONCodersTests.swift
git commit -m "M1.7: shared JSON coder helpers"
```

---

## Task 8 — Full SharedKit suite green + DocC stub

- [ ] **Step 1: Run the full SharedKit suite**

Run: `swift test --filter SharedKitTests`
Expected: all suites pass; `Tests passed: ≥ 22` (4 + 3 + 6 + 5 + 6 + 2).

- [ ] **Step 2: Run a release build to catch warnings**

Run: `swift build -c release`
Expected: `Build complete!` with no warnings. If warnings appear, fix at the source (e.g. unused vars), do not add `// swiftlint:disable` style suppressions.

- [ ] **Step 3: Commit any cleanup if step 2 produced fixes**

```bash
git status
# only commit if there is something
git commit -am "M1.8: silence release-build warnings"
```

---

## Exit criteria

Run all of the following at the end and paste the output into the merge commit body:

```bash
swift --version
swift test --filter SharedKitTests 2>&1 | tail -5
swift build -c release 2>&1 | tail -3
```

Required:
- `swift test` reports `0 failures` for the SharedKit suite
- `swift build -c release` succeeds with no warnings
- Every public type in `Sources/SharedKit/` has at least one test that constructs it (you can verify by `grep -R "public " Sources/SharedKit | grep -v //` then ensuring each appears in `Tests/SharedKitTests/`)

## Self-review

- [ ] **Coverage:** `JSONRPC` ✔ `Models` ✔ `Screen` ✔ `DiffOp` ✔ `KeyEncoder` ✔ `WireProtocol` ✔ `JSONCoders` ✔
- [ ] **Placeholder scan:** `grep -RnE "TODO|FIXME|fill in|tbd" Sources/SharedKit/` returns no hits
- [ ] **Type consistency:** `RPCRequest.id` and `RPCResponse.id` are both `Int64`. `Screen.cursor` is `CursorPos`, used identically by `ScreenFull.cursor`. `DiffOp.row.y` is `Int` and matches `CursorPos.y`.

## Merge

```bash
git checkout main
git merge --ff-only m1-sharedkit
git branch -d m1-sharedkit
```

Pick up M2 next: `2026-05-09-m2-cmux-client-diff-engine.md`.
