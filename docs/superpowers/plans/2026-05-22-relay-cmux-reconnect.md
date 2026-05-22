# Relay ↔ cmux auto-reconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the relay automatically re-establish its cmux Unix-domain-socket connection (and the `events.stream` subscription) after a drop, so the iPhone no longer needs a relay restart to recover from `channelClosed`.

**Architecture:** Encapsulate the cached `CMUXClient` + single-flight dial in a small generic `actor ReconnectingResource<R>`. `CmuxConnection` (still a class) delegates `connect()`/`connectForEvents()` to two such resources, so a dead client is transparently re-dialed. A supervised loop in `CmuxRelay` re-attaches the event stream with capped exponential backoff (`ReconnectPolicy`). The new logic is unit-tested with no NIO; the NIO/glue is verified by build + manual integration.

**Tech Stack:** Swift 5.10, SwiftPM, SwiftNIO, swift-log, XCTest. Server packages (`RelayCore`, `CMUXClient`, `RelayServer`) are SPM targets — tested via `swift test` (no simulator).

**Spec:** `docs/superpowers/specs/2026-05-22-relay-cmux-reconnect-design.md`

---

## File Structure

- **Create** `Sources/RelayCore/ReconnectPolicy.swift` — pure capped-exponential backoff value type.
- **Create** `Sources/RelayCore/ReconnectingResource.swift` — generic `actor` owning a cached resource + single-flight re-dial.
- **Create** `Tests/RelayCoreTests/ReconnectPolicyTests.swift`
- **Create** `Tests/RelayCoreTests/ReconnectingResourceTests.swift`
- **Modify** `Sources/CMUXClient/CMUXClient.swift` — add `isUsable()` and `awaitClosed()`.
- **Modify** `Sources/RelayCore/CmuxConnection.swift` — delegate to `ReconnectingResource`; add `invalidateEvents()`; keep `observe()`/`onReset`/`lastBootId` untouched.
- **Modify** `Sources/RelayServer/CmuxRelay.swift` — replace the one-shot event-stream `Task` with a supervised reconnect loop.

---

## Task 0: Feature branch

- [ ] **Step 1: Create and switch to a feature branch**

The repo is on `main` (default). Branch before any change.

Run:
```bash
cd /Users/genie/dev/side/cmux-iphone
git checkout -b fix/relay-cmux-reconnect
```
Expected: `Switched to a new branch 'fix/relay-cmux-reconnect'`

- [ ] **Step 2: Commit the design + plan docs**

```bash
cd /Users/genie/dev/side/cmux-iphone
git add docs/superpowers/specs/2026-05-22-relay-cmux-reconnect-design.md docs/superpowers/plans/2026-05-22-relay-cmux-reconnect.md
git commit -m "docs: spec + plan for relay↔cmux auto-reconnect"
```

---

## Task 1: ReconnectPolicy (pure backoff)

**Files:**
- Create: `Sources/RelayCore/ReconnectPolicy.swift`
- Test: `Tests/RelayCoreTests/ReconnectPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/RelayCoreTests/ReconnectPolicyTests.swift`:
```swift
import XCTest
@testable import RelayCore

final class ReconnectPolicyTests: XCTestCase {
    func testBackoffSequenceIsCappedExponential() {
        var p = ReconnectPolicy(base: 0.5, cap: 8.0)
        XCTAssertEqual(p.nextDelay(), 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.nextDelay(), 1.0, accuracy: 1e-9)
        XCTAssertEqual(p.nextDelay(), 2.0, accuracy: 1e-9)
        XCTAssertEqual(p.nextDelay(), 4.0, accuracy: 1e-9)
        XCTAssertEqual(p.nextDelay(), 8.0, accuracy: 1e-9)
        XCTAssertEqual(p.nextDelay(), 8.0, accuracy: 1e-9, "stays capped")
    }

    func testResetReturnsToBase() {
        var p = ReconnectPolicy(base: 0.5, cap: 8.0)
        _ = p.nextDelay()
        _ = p.nextDelay()
        p.reset()
        XCTAssertEqual(p.nextDelay(), 0.5, accuracy: 1e-9)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/genie/dev/side/cmux-iphone && swift test --filter ReconnectPolicyTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'ReconnectPolicy' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/RelayCore/ReconnectPolicy.swift`:
```swift
import Foundation

/// Capped exponential backoff for the cmux event-stream supervisor.
/// `nextDelay()` returns seconds and advances the attempt counter;
/// `reset()` is called after a successful (long-lived) attach so the
/// next reconnect starts fast again.
public struct ReconnectPolicy {
    private let base: Double
    private let cap: Double
    private var attempt: Int = 0

    public init(base: Double = 0.5, cap: Double = 8.0) {
        self.base = base
        self.cap = cap
    }

    public mutating func nextDelay() -> Double {
        let raw = base * pow(2.0, Double(attempt))
        attempt += 1
        return min(cap, raw)
    }

    public mutating func reset() {
        attempt = 0
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/genie/dev/side/cmux-iphone && swift test --filter ReconnectPolicyTests 2>&1 | tail -20`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/genie/dev/side/cmux-iphone
git add Sources/RelayCore/ReconnectPolicy.swift Tests/RelayCoreTests/ReconnectPolicyTests.swift
git commit -m "feat(relay): add ReconnectPolicy capped-exponential backoff"
```

---

## Task 2: ReconnectingResource (generic re-dial actor)

**Files:**
- Create: `Sources/RelayCore/ReconnectingResource.swift`
- Test: `Tests/RelayCoreTests/ReconnectingResourceTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/RelayCoreTests/ReconnectingResourceTests.swift`:
```swift
import XCTest
@testable import RelayCore

final class ReconnectingResourceTests: XCTestCase {
    /// Controllable fake "resource opener" used as `R = Int`.
    private actor Fake {
        private(set) var openCount = 0
        private var alive = true
        private var delayNanos: UInt64 = 0

        func setAlive(_ b: Bool) { alive = b }
        func setDelay(_ n: UInt64) { delayNanos = n }

        func open() async -> Int {
            if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
            openCount += 1
            return openCount
        }
        func isAlive(_ value: Int) -> Bool { alive }
    }

    func testCachesWhileAlive() async throws {
        let fake = Fake()
        let res = ReconnectingResource<Int>(
            open: { await fake.open() },
            isAlive: { await fake.isAlive($0) })
        let a = try await res.get()
        let b = try await res.get()
        XCTAssertEqual(a, 1)
        XCTAssertEqual(b, 1)
        let count = await fake.openCount
        XCTAssertEqual(count, 1, "a living cached resource must not be re-opened")
    }

    func testReopensWhenDead() async throws {
        let fake = Fake()
        let res = ReconnectingResource<Int>(
            open: { await fake.open() },
            isAlive: { await fake.isAlive($0) })
        _ = try await res.get()        // opens -> 1
        await fake.setAlive(false)
        let second = try await res.get() // dead -> re-open -> 2
        XCTAssertEqual(second, 2)
        let count = await fake.openCount
        XCTAssertEqual(count, 2)
    }

    func testInvalidateForcesReopen() async throws {
        let fake = Fake()
        let res = ReconnectingResource<Int>(
            open: { await fake.open() },
            isAlive: { await fake.isAlive($0) })
        _ = try await res.get()
        await res.invalidate()
        _ = try await res.get()
        let count = await fake.openCount
        XCTAssertEqual(count, 2)
    }

    func testSingleFlightUnderConcurrentGets() async throws {
        let fake = Fake()
        await fake.setDelay(20_000_000) // 20ms so the three gets overlap
        let res = ReconnectingResource<Int>(
            open: { await fake.open() },
            isAlive: { await fake.isAlive($0) })
        async let g1 = res.get()
        async let g2 = res.get()
        async let g3 = res.get()
        let results = try await [g1, g2, g3]
        XCTAssertEqual(results, [1, 1, 1])
        let count = await fake.openCount
        XCTAssertEqual(count, 1, "concurrent gets must share a single open()")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/genie/dev/side/cmux-iphone && swift test --filter ReconnectingResourceTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'ReconnectingResource' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/RelayCore/ReconnectingResource.swift`:
```swift
/// Owns a single cached resource (e.g. a `CMUXClient`) and transparently
/// re-opens it when it is no longer alive. Concurrent `get()` callers that
/// arrive while a dial is in flight share that one dial (single-flight).
public actor ReconnectingResource<R: Sendable> {
    private var cached: R?
    private var inFlight: Task<R, Error>?
    private let open: @Sendable () async throws -> R
    private let isAlive: @Sendable (R) async -> Bool

    public init(open: @escaping @Sendable () async throws -> R,
                isAlive: @escaping @Sendable (R) async -> Bool) {
        self.open = open
        self.isAlive = isAlive
    }

    public func get() async throws -> R {
        if let c = cached, await isAlive(c) { return c }
        cached = nil
        if let t = inFlight { return try await t.value }
        let t = Task { try await self.open() }
        inFlight = t
        defer { inFlight = nil }
        let c = try await t.value
        cached = c
        return c
    }

    public func invalidate() {
        cached = nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/genie/dev/side/cmux-iphone && swift test --filter ReconnectingResourceTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/genie/dev/side/cmux-iphone
git add Sources/RelayCore/ReconnectingResource.swift Tests/RelayCoreTests/ReconnectingResourceTests.swift
git commit -m "feat(relay): add ReconnectingResource single-flight re-dial actor"
```

---

## Task 3: CMUXClient liveness + close-await

**Files:**
- Modify: `Sources/CMUXClient/CMUXClient.swift` (add two methods after `didClose()` at line 158–160)

This is thin NIO glue (per spec it is verified by build + manual integration, not a unit test that would fight `EmbeddedChannel` threading). No new test here.

- [ ] **Step 1: Add `isUsable()` and `awaitClosed()`**

In `Sources/CMUXClient/CMUXClient.swift`, inside the `public actor CMUXClient` body, add these methods immediately after the existing `fileprivate func didClose()` method:
```swift
    /// True only while the underlying channel is live and no terminal
    /// (channelClosed) error has been recorded. `CmuxConnection` uses this
    /// to decide whether a cached client can be reused or must be re-dialed.
    public func isUsable() -> Bool {
        channel.isActive && terminalError == nil
    }

    /// Suspends until the underlying channel closes. The event-stream
    /// supervisor awaits this to know when to re-attach.
    public func awaitClosed() async {
        _ = try? await channel.closeFuture.get()
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd /Users/genie/dev/side/cmux-iphone && swift build --target CMUXClient 2>&1 | tail -20`
Expected: build succeeds (no errors).

- [ ] **Step 3: Commit**

```bash
cd /Users/genie/dev/side/cmux-iphone
git add Sources/CMUXClient/CMUXClient.swift
git commit -m "feat(cmuxclient): expose isUsable() and awaitClosed()"
```

---

## Task 4: CmuxConnection delegates to ReconnectingResource

**Files:**
- Modify: `Sources/RelayCore/CmuxConnection.swift` (replace `connect()`, `connectForEvents()`, `openClient()`; add `invalidateEvents()`; keep `observe()`/`onReset`/`lastBootId`)
- Safety net: existing `Tests/RelayCoreTests/CmuxConnectionTests.swift` (must stay green, unchanged)

This is a refactor under existing test coverage. `observe()`, `onReset`, and `lastBootId` are untouched, so the boot_id tests still pass; the new re-dial behavior is proven by `ReconnectingResourceTests`.

- [ ] **Step 1: Replace the client-cache fields and methods**

In `Sources/RelayCore/CmuxConnection.swift`:

Replace the two stored client fields (currently lines 23–24):
```swift
    private var dispatchClient: CMUXClient?
    private var eventsClient: CMUXClient?
```
with:
```swift
    private let dispatchResource: ReconnectingResource<CMUXClient>
    private let eventsResource: ReconnectingResource<CMUXClient>
```

In `init` (currently lines 26–33), set the resources at the end of the body. Replace the whole initializer with:
```swift
    public init(socketPath: String = cmuxSocketPath(),
                group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1),
                socketPassword: String? = cmuxSocketPassword())
    {
        self.socketPath = socketPath
        self.group = group
        self.socketPassword = socketPassword
        let opener: @Sendable () async throws -> CMUXClient = {
            try await CmuxConnection.openClient(socketPath: socketPath,
                                                group: group,
                                                socketPassword: socketPassword)
        }
        let alive: @Sendable (CMUXClient) async -> Bool = { await $0.isUsable() }
        self.dispatchResource = ReconnectingResource(open: opener, isAlive: alive)
        self.eventsResource = ReconnectingResource(open: opener, isAlive: alive)
    }
```

Replace `connect()` (currently lines 45–50):
```swift
    public func connect() async throws -> CMUXClient {
        try await dispatchResource.get()
    }
```

Replace `connectForEvents()` (currently lines 57–62):
```swift
    public func connectForEvents() async throws -> CMUXClient {
        try await eventsResource.get()
    }

    /// Drop the cached events client so the supervisor's next
    /// `connectForEvents()` re-dials after a detach.
    public func invalidateEvents() async {
        await eventsResource.invalidate()
    }
```

Replace the instance `openClient()` (currently lines 64–77) with a `static` version that the opener closure can call without capturing `self`:
```swift
    private static func openClient(socketPath: String,
                                   group: EventLoopGroup,
                                   socketPassword: String?) async throws -> CMUXClient {
        let chan = try await UnixSocketChannel(path: socketPath, group: group)
            .connect { _ in group.next().makeSucceededFuture(()) }
        let c = CMUXClient(channel: chan, requestTimeout: .seconds(5))
        // CMUXClient installs its inbound bridge in a fire-and-forget Task in
        // its initializer; await readiness so the first RPC isn't dropped.
        await c.awaitReady()
        if let socketPassword {
            try await c.authenticate(password: socketPassword)
        }
        return c
    }
```

Leave `makeForTesting()`, `observe(bootInfo:)`, `onReset`, `lastBootId`, `socketPath`, `group`, `socketPassword`, and `logger` exactly as they are.

- [ ] **Step 2: Build to verify it compiles**

Run: `cd /Users/genie/dev/side/cmux-iphone && swift build --target RelayCore 2>&1 | tail -20`
Expected: build succeeds.

- [ ] **Step 3: Run existing CmuxConnection tests to confirm no regression**

Run: `cd /Users/genie/dev/side/cmux-iphone && swift test --filter CmuxConnectionTests 2>&1 | tail -20`
Expected: PASS (2 tests: `testBootIdChangeFiresReset`, `testFirstObservationDoesNotFireReset`).

- [ ] **Step 4: Commit**

```bash
cd /Users/genie/dev/side/cmux-iphone
git add Sources/RelayCore/CmuxConnection.swift
git commit -m "fix(relay): re-dial cmux client via ReconnectingResource instead of caching forever"
```

---

## Task 5: Supervised event-stream reconnect loop

**Files:**
- Modify: `Sources/RelayServer/CmuxRelay.swift` (replace the one-shot `Task` at lines 53–69)

The relay executable target is not unit-tested for this loop (it drives real NIO + a live cmux); it is verified by build + the manual integration check in Task 6.

- [ ] **Step 1: Replace the one-shot event-stream Task with a supervised loop**

In `Sources/RelayServer/CmuxRelay.swift`, replace the existing block:
```swift
        Task {
            do {
                let client = try await conn.connectForEvents()
                let stream = EventStream(client: client) { event in
                    if event.category == .system,
                       let boot = try? event.payload.decode(BootInfo.self)
                    {
                        conn.observe(bootInfo: boot)
                    }
                    Task { await manager.broadcastToAll(frame: .event(event)) }
                }
                await stream.start(categories: EventCategory.allCases)
                logger.info("cmux event stream attached")
            } catch {
                logger.warning("cmux event stream unavailable: \(String(describing: error))")
            }
        }
```
with:
```swift
        Task {
            var policy = ReconnectPolicy()
            while !Task.isCancelled {
                do {
                    let client = try await conn.connectForEvents()
                    let stream = EventStream(client: client) { event in
                        if event.category == .system,
                           let boot = try? event.payload.decode(BootInfo.self)
                        {
                            conn.observe(bootInfo: boot)
                        }
                        Task { await manager.broadcastToAll(frame: .event(event)) }
                    }
                    await stream.start(categories: EventCategory.allCases)
                    logger.info("cmux event stream attached")
                    policy.reset()
                    await client.awaitClosed()
                    logger.warning("cmux event stream detached; will re-attach")
                    await conn.invalidateEvents()
                } catch {
                    logger.warning("cmux event stream unavailable: \(String(describing: error))")
                }
                let delay = policy.nextDelay()
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
```

- [ ] **Step 2: Build the relay executable**

Run: `cd /Users/genie/dev/side/cmux-iphone && swift build --target RelayServer 2>&1 | tail -20`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
cd /Users/genie/dev/side/cmux-iphone
git add Sources/RelayServer/CmuxRelay.swift
git commit -m "fix(relay): supervise cmux event stream with backoff re-attach"
```

---

## Task 6: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Full build + full test suite**

Run: `cd /Users/genie/dev/side/cmux-iphone && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30`
Expected: build succeeds; all tests pass (existing suites + `ReconnectPolicyTests` + `ReconnectingResourceTests` + unchanged `CmuxConnectionTests`).

- [ ] **Step 2: Install the rebuilt relay binary**

The launchd agent runs `~/.cmuxremote/bin/cmux-relay`. Copy the freshly built binary over it, then restart via the cmux-manage control script.

Run:
```bash
cd /Users/genie/dev/side/cmux-iphone
swift build -c release 2>&1 | tail -5
cp .build/release/cmux-relay ~/.cmuxremote/bin/cmux-relay
bash ~/.claude/skills/cmux-manage/scripts/cmux-relay.sh restart
```
Expected: restart prints `state = running` with a new pid; `stderr.log` shows `starting … / listening … / cmux event stream attached`.

- [ ] **Step 3: Manual integration check — cmux restart**

With the iPhone app connected:
1. Quit the cmux app, wait ~5s, reopen it.
2. Tail the relay log: `tail -n 20 ~/.cmuxremote/log/stderr.log`

Expected log sequence: `cmux event stream attached` → (on quit) `cmux event stream detached; will re-attach` → (on reopen) `cmux event stream attached` — **without** restarting the relay. iPhone RPCs work again without a manual reconnect or relay restart.

- [ ] **Step 4: Manual integration check — Mac sleep/wake**

1. Sleep the Mac (or close the lid) for ~1 minute on battery, then wake it.
2. From the iPhone app, trigger any action.

Expected: the relay re-dials cmux on the next dispatch (no `channelClose` surfaced to the app), and the event stream re-attaches per the log. No relay restart needed.

- [ ] **Step 5: Final state**

Confirm the working tree is clean and on `fix/relay-cmux-reconnect`:
Run: `cd /Users/genie/dev/side/cmux-iphone && git status -sb && git log --oneline -8`
Expected: clean tree; commits for docs, ReconnectPolicy, ReconnectingResource, CMUXClient, CmuxConnection, CmuxRelay.

---

## Self-Review notes

- **Spec coverage:** §Design.1 → Task 3; §Design.2 (ReconnectingResource + wiring) → Tasks 2, 4; §Design.3 (supervisor) → Task 5; §Design.4 (dispatch recovery) → follows from Task 4 (lazy re-dial via `isUsable`), exercised in Task 6 Step 3; `ReconnectPolicy` → Task 1; Testing strategy → Tasks 1, 2 (unit) + Task 6 (integration).
- **Type consistency:** `ReconnectPolicy.nextDelay()/reset()`, `ReconnectingResource.get()/invalidate()`, `CMUXClient.isUsable()/awaitClosed()`, `CmuxConnection.connect()/connectForEvents()/invalidateEvents()` are used identically across tasks.
- **No placeholders:** every code step contains complete code; every run step has an exact command + expected outcome.
