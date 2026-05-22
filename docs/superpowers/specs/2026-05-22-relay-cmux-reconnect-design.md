# Relay ↔ cmux auto-reconnect — design

- **Date:** 2026-05-22
- **Status:** Approved (pre-implementation)
- **Area:** `Sources/RelayCore/CmuxConnection.swift`, `Sources/RelayServer/CmuxRelay.swift`, `Sources/CMUXClient/CMUXClient.swift`

## Problem

The iPhone app keeps requiring a manual reconnect / relay restart to talk to cmux.
The user observes a `channelClose` error and the connection fails until the relay
process is restarted (via the `cmux-manage` skill).

## Root cause (confirmed in code)

There are two distinct connections in the system:

1. iPhone ↔ relay — WebSocket over Tailscale (`WSClient` / `WebSocketHandler`).
2. relay ↔ cmux app — Unix domain socket (`cmux.sock`), driven by `CMUXClient`.

`channelClose` is `CMUXClientError.channelClosed` — it belongs to connection (2),
**not** the iPhone WebSocket.

`CmuxConnection`'s doc comment claims it *"Owns the long-lived CMUXClient
connection to the cmux UDS, recovers from disconnects"* — but the implementation
does **not** recover:

- `connect()` (`CmuxConnection.swift:45`) caches `dispatchClient` for the process
  lifetime and always returns it. No liveness check, no invalidation, no re-dial.
- `connectForEvents()` (`:57`) caches `eventsClient` the same way.
- The event-stream setup (`CmuxRelay.swift:53–69`) is a **one-shot `Task`**: it
  attaches once, logs `cmux event stream attached`, and ends. No retry loop.
- Once the UDS channel goes inactive (cmux quit/restart, Mac sleep suspending cmux,
  or an idle drop), `CMUXClient.didClose()` sets `terminalError = .channelClosed`
  **permanently** (`CMUXClient.swift:158–160`). Every subsequent `call()` throws
  the cached terminal error immediately (`:50–52`).

Net effect: after the first UDS disconnect, the relay's `CMUXClient` is bricked.
All iPhone RPCs fail with `channelClosed`, and the event stream stays detached.
The only recovery is restarting the relay process. This exactly matches the
"must reconnect/restart every session" symptom.

Trigger is not reliably known to the user ("both / not sure; broken after it sits
a while") — so the fix must be **trigger-agnostic**: a supervised reconnect that
recovers regardless of whether cmux quit, the Mac slept, or the socket idled out.

## Answers to the original questions

| Question | Answer |
|---|---|
| Is it a cmux-iphone code problem? | Yes — the **relay side** (`Sources/RelayCore/CmuxConnection.swift`), not the iOS app. |
| Does the cmux app need periodic restart? | No. cmux quitting/sleeping is only the *trigger*; the fix is the relay's reconnect logic. |

## Goals

- The relay re-establishes its cmux UDS connection automatically after a drop,
  with no relay-process restart.
- The `events.stream` subscription re-attaches automatically after a drop, and a
  cmux restart (boot_id change) still drives `broadcastReset`.
- Core recovery logic is deterministically unit-testable via `swift test`
  (RelayCoreTests), without a simulator or a live cmux.

## Non-goals (explicit)

- iPhone `WSClient` heartbeat / foreground reconnect. This is a separate latent
  robustness gap on connection (1); it does **not** produce `channelClose`.
- macOS power-management changes (separate environment track).
- Server-side WebSocket ping (the server is suspended during Mac sleep anyway).

## Design

### 1. `CMUXClient` — minimal additions

- Add `func isUsable() async -> Bool` returning `channel.isActive && terminalError == nil`,
  used by `CmuxConnection` to decide whether the cached client can be reused.
- Channel-death detection: keep the NIO `chan` created in `openClient()` inside
  `CmuxConnection` and observe `chan.closeFuture` for liveness/close. This avoids
  adding lifecycle callbacks to `CMUXClient`.

### 2. `ReconnectingResource<R>` (new, RelayCore) + `CmuxConnection` wiring

**Refinement of the original "convert to actor" idea.** Rather than converting
the whole `CmuxConnection` to an actor (which would ripple into its synchronous
`observe()` / `onReset` API and the existing boot_id tests), encapsulate *only*
the new concurrent state — the cached client + single-flight dial — in a small
generic actor. This achieves the same goal (no cache data race, serialized
re-dial) with a far smaller blast radius and a fully unit-testable core.

```swift
actor ReconnectingResource<R: Sendable> {
    private var cached: R?
    private var inFlight: Task<R, Error>?
    private let open: @Sendable () async throws -> R
    private let isAlive: @Sendable (R) async -> Bool

    func get() async throws -> R {
        if let c = cached, await isAlive(c) { return c }
        if let t = inFlight { return try await t.value }   // share the dial
        let t = Task { try await open() }
        inFlight = t
        defer { inFlight = nil }
        let c = try await t.value
        cached = c
        return c
    }
    func invalidate() { cached = nil }
}
```

- `CmuxConnection` stays a `final class @unchecked Sendable`. Its `observe()`,
  `onReset`, and `lastBootId` are untouched, so the existing `CmuxConnectionTests`
  pass unchanged. It now holds two `ReconnectingResource<CMUXClient>` (dispatch +
  events).
- `connect()` → `try await dispatchResource.get()`; `connectForEvents()` →
  `try await eventsResource.get()`. The `open` closure is the existing
  `openClient()` logic; `isAlive` is `{ await $0.isUsable() }`.
- Add `invalidateEvents()` → `await eventsResource.invalidate()` for the supervisor.
- Re-dial / single-flight / cache correctness is proven by
  `ReconnectingResourceTests` (generic, `R = Int`, no NIO). The wiring in
  `CmuxConnection` is thin glue verified by build + manual integration.

### 3. Event-stream supervisor (`CmuxRelay.swift`)

Replace the one-shot `Task` with a supervised loop:

```
Task {
  var policy = ReconnectPolicy()
  while !Task.isCancelled {
    do {
      let client = try await conn.connectForEvents()
      let stream = EventStream(client: client) { event in
        // observe(bootInfo:) for boot_id reset + broadcastToAll
      }
      await stream.start(categories: EventCategory.allCases)
      logger.info("cmux event stream attached")
      policy.reset()
      await conn.awaitEventsChannelClose()      // suspends until UDS dies
      logger.warning("cmux event stream detached; will re-attach")
      await conn.invalidateEvents()
    } catch {
      logger.warning("cmux event stream unavailable: \(error)")
    }
    try? await Task.sleep(for: policy.nextDelay())
  }
}
```

- On re-attach after a cmux restart, the new boot_id differs from `lastBootId`,
  so `observe(bootInfo:)` fires `onReset` → `SessionManager.broadcastReset()`.
  This now works because the stream is actually re-established (previously the
  one-shot Task had already exited and could never see the new boot frame).

### 4. Dispatch-side recovery (follows automatically)

`CMUXFacadeImpl.dispatch` already calls `connection.connect()` per request. With
re-dialing `connect()`, a request that previously threw a terminal `channelClosed`
now transparently re-dials and succeeds. While cmux is genuinely down, dispatch
fails with a real (non-terminal) error that the iPhone retries; when cmux returns,
the next dispatch re-dials and succeeds. No relay restart required.

### `ReconnectPolicy` (new, RelayCore) — pure backoff

Small value type producing a capped exponential backoff sequence with `reset()`.
No clock, no I/O. Drives the supervisor's `Task.sleep`. Default sequence (tunable):
0.5s, 1s, 2s, 4s, 8s, capped at 8s.

## Concurrency model

- The cached client + dial state live in `ReconnectingResource` (an `actor`), so
  all cache mutation is actor-isolated. `CmuxConnection` itself stays a class but
  no longer owns mutable client cache state.
- Single-flight dial (`inFlight` task reuse) avoids duplicate `open()` under
  concurrent `get()`.
- The supervisor loop is the sole owner of events re-attach; dispatch re-dial is
  independent and idempotent under single-flight.
- `observe()` / `lastBootId` remain serialized in practice: event frames are
  delivered through the `CMUXClient` actor's `deliver`, so the sink (and thus
  `observe`) is never called concurrently.

## Testing strategy (`swift test`, RelayCoreTests — no simulator)

- `ReconnectPolicyTests`: backoff sequence + `reset()` are deterministic.
- `ReconnectingResourceTests` (generic, `R = Int`, no NIO):
  - first `get()` opens once; second returns cache (open called once);
  - after `isAlive` flips false, `get()` re-dials (open called twice);
  - `invalidate()` forces the next `get()` to re-dial;
  - concurrent `get()` during a slow `open()` → open called once (single-flight).
- Existing `CmuxConnectionTests` (`observe()` / boot_id) stay green, unchanged.
- **Integration / manual:** run relay, connect iPhone, quit+reopen cmux (or sleep+
  wake the Mac); confirm logs show `detached` → `attached` and iPhone RPCs recover
  **without** restarting the relay.

## Risks / edge cases

- **cmux truly down:** `openClient()` throws; dispatch surfaces a transient error
  (not terminal). Correct — recovers on next dispatch once cmux returns.
- **Reconnect storm:** capped backoff + single-flight bound the dial rate.
- **boot_id reset ordering:** reset must fire after the stream re-subscribes so
  sessions rebuild against the new cmux instance.
- **CMUXClient + NIO threading:** `isUsable()` / `awaitClosed()` touch the NIO
  `Channel`; they are thin glue verified by build + manual integration rather than
  by unit tests that would have to fight `EmbeddedChannel` threading. `connect()` /
  `connectForEvents()` keep their existing `async` signatures, so `CMUXFacadeImpl`
  and `CmuxSurfaceReader` are unaffected.
