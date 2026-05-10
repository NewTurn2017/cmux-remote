# cmux-iphone-bridge — Design Spec

- **Date**: 2026-05-09
- **Status**: Draft, ready for implementation planning
- **Owner**: genie (hyuni2020@gmail.com)
- **Repo**: `~/dev/side/cmux-iphone/`

## 1. Goal

Build an iPhone-only native client that drives the user's local cmux (running on their Mac) over their existing Tailscale tailnet. The phone must be able to:

1. List, switch, and create cmux workspaces
2. View terminal output of any surface in near real-time and send keystrokes back
3. Receive cmux notifications as proper iOS push (lock screen, background) via APNs

The MVP must work without modifying cmux itself.

## 2. Non-goals (v1.0)

- Public-internet exposure (Tailscale Funnel) — kept behind tailnet
- Multi-user / sharing
- Perfect rendering of high-rate TUIs (vim, htop) — left for v2.0 byte-stream RPC
- iPad layout
- Android client

## 3. High-level architecture

```
iPhone (iOS 17+)         Tailscale            Mac
┌────────────────────┐                        ┌────────────────────────────────┐
│  CmuxRemote (SwiftUI)│ ── HTTPS+WSS ───────▶ │ cmux-relay (Swift, launchd)    │
│  ─ WorkspaceList    │                        │  ─ HTTP REST (REST is minimal)│
│  ─ TerminalView     │ ◀──── APNs push ─────  │  ─ /v1/stream WebSocket       │
│  ─ AccessoryBar     │       (apns prov)      │  ─ DiffEngine (15 Hz polling) │
│  ─ NotificationCenter│                       │  ─ APNsClient                 │
└────────────────────┘                         │  ─ EventForwarder             │
                                               └─────────────┬──────────────────┘
                                                             │ Unix socket
                                                             │ JSON-RPC 2.0
                                                             ▼
                                               ┌────────────────────────────────┐
                                               │  cmux.app (Ghostty)            │
                                               │  /tmp/cmux.sock                │
                                               └────────────────────────────────┘
```

Four code units:

| Unit | Where | Purpose |
|---|---|---|
| `SharedKit` | `Sources/SharedKit/` | Codable models, JSON-RPC envelope, `DiffOp`, key-encoding tables. macOS 13+ / iOS 17+ |
| `CMUXClient` | `Sources/CMUXClient/` | Unix-socket JSON-RPC client to `/tmp/cmux.sock`. Mac-only |
| `RelayCore` | `Sources/RelayCore/` | Auth, session lifecycle, polling DiffEngine, APNs sender, rate limit |
| `RelayServer` | `Sources/RelayServer/` | `@main`, swift-nio HTTP+WS, tsnet integration, launchd entrypoint, menu-bar UI for device revocation |
| `iOSApp` | `ios/CmuxRemote/` | SwiftUI app, depends on `SharedKit` |

## 4. Project layout

```
~/dev/side/cmux-iphone/
├─ README.md
├─ docs/
│  ├─ specs/2026-05-09-cmux-iphone-bridge-design.md   ← this file
│  └─ specs/<future plan and decision docs>
├─ Package.swift
├─ Sources/
│  ├─ SharedKit/
│  ├─ CMUXClient/
│  ├─ RelayCore/
│  └─ RelayServer/
├─ Tests/
│  ├─ SharedKitTests/
│  ├─ DiffEngineTests/
│  ├─ CMUXClientTests/
│  └─ RelayCoreTests/
├─ ios/
│  ├─ CmuxRemote.xcodeproj
│  └─ CmuxRemote/                ← SwiftUI app, SharedKit local-package dep
└─ scripts/
   ├─ install-launchd.sh
   ├─ uninstall-launchd.sh
   └─ apns-key-rotate.sh
```

## 5. External dependencies

| Where | Dep | License | Purpose |
|---|---|---|---|
| RelayServer | `apple/swift-nio` | Apache-2.0 | HTTP + WebSocket |
| RelayServer | `apple/swift-nio-ssl` | Apache-2.0 | TLS |
| RelayServer | `apple/swift-log` | Apache-2.0 | Logging |
| RelayServer | `apple/swift-argument-parser` | Apache-2.0 | CLI flags |
| RelayServer | `apple/swift-crypto` | Apache-2.0 | Argon2id, hashing |
| RelayServer | `swift-server/async-http-client` | Apache-2.0 | APNs HTTP/2 client |
| RelayServer | `tailscale/tailscale` `tsnet` (via libtailscale) | BSD-3-Clause | Read peer Tailscale identity |
| iOSApp | `securing/IOSSecuritySuite` | MIT | Jailbreak / debugger detection |
| iOSApp | (built-in) `URLSessionWebSocketTask`, `UserNotifications`, `Network`, `CryptoKit` | — | — |

### Reference codebases (read for patterns, do not copy)

- **Blink Shell** (`blinksh/blink`, GPLv3) — keyboard accessory + arrow-drag gesture patterns. Clean-room re-implementation only. Commits that adapt structure must say "patterns adapted from Blink Shell (GPLv3)".
- **termius/IOSSecuritySuite** (MIT) — used as a binary dep, not as inspiration.
- **termius/termius-cli** (Apache-2.0) — concept only: snippet/host-group data model.

## 6. Wire protocol

### 6.1 Endpoints

```
POST   /v1/devices/me/apns       { apns_token, env }            → 204
DELETE /v1/devices/me                                            → 204

GET    /v1/health                                                → 200 {ok}
GET    /v1/state                                                 → snapshot

WS     /v1/stream                ← main channel
```

WebSocket sub-protocol header: `Sec-WebSocket-Protocol: cmuxremote.v1, bearer.<device_token>`. Server must receive a `hello` frame from the client within 100 ms or close.

### 6.2 JSON-RPC envelope

This is the cmux-socket v2 envelope (NOT JSON-RPC 2.0). Verified against the cmux 2026-05 source at `manaflow-ai/cmux/CLI/cmux.swift`.

Client → Server (request) — newline-delimited:
```json
{ "id": "<uuid>", "method": "workspace.list", "params": {} }
{ "id": "<uuid>", "method": "surface.subscribe", "params": { "surface_id": "...", "fps": 15 } }
{ "id": "<uuid>", "method": "events.subscribe", "params": { "categories": ["notification","workspace","surface"] } }
```

Server → Client (response) — newline-delimited:
```json
{ "id": "<echoed>",  "result": { "workspaces": [...] } }
{ "id": "<echoed>", "ok": false, "error": { "code": "method_not_found", "message": "..." } }
```

Differences from textbook JSON-RPC 2.0:
- `id` is a **string** (typically UUID), not an integer.
- Success envelopes **omit `ok`** and provide `result`. Error envelopes set `ok: false` with `error: { code, message }`.
- `error.code` is a **string symbol** (`"method_not_found"`, `"forbidden"`, …), not a numeric code.

Server → Client (push, no `id`):
```json
{ "type": "screen.full", "surface_id": "...", "rev": 0,  "rows": [...], "cols": 120, "rowsCount": 30 }
{ "type": "screen.diff", "surface_id": "...", "rev": 42, "ops": [
    { "op": "row",    "y": 7, "text": "$ ls\u001b[0m" },
    { "op": "cursor", "x": 0, "y": 9 }
] }
{ "type": "screen.checksum", "surface_id": "...", "rev": 42, "hash": "..." }
{ "type": "event", "category": "notification", "name": "notification.created", "payload": {...} }
{ "type": "ping",  "ts": 1714000000 }
```

### 6.3 cmux RPC mapping (relay → cmux)

| Client method | Cmux v2 method on Unix socket |
|---|---|
| `workspace.list` | `workspace.list` |
| `workspace.create` | `workspace.create` |
| `workspace.select` | `workspace.select` |
| `workspace.close` | `workspace.close` |
| `surface.list` | `surface.list` |
| `surface.send_text` | `surface.send_text` |
| `surface.send_key` | `surface.send_key` |
| `surface.subscribe` | (relay-internal) start `DiffEngine` polling `surface.read_text` |
| `surface.unsubscribe` | (relay-internal) stop `DiffEngine` |
| `events.subscribe` | `events.stream` (one persistent cmux connection per relay process, fanned out to all WS clients) |
| `notification.create` | `notification.create` |

The set above is the v1.0 surface area. Anything else (browser, vm, …) is intentionally not exposed in v1.

### 6.4 DiffEngine

In `RelayCore/DiffEngine.swift`:

1. On `surface.subscribe`, send `screen.full` once; record per-row `xxhash64`.
2. Every `1/fps` seconds, call `surface.read_text { workspace_id, surface_id, lines: viewport }`.
3. Compare each line's hash; for every changed line emit `{op:"row", y, text}` preserving raw ANSI escapes.
4. Track cursor position from cmux response; emit `{op:"cursor", x, y}` only on change.
5. Every 5 s, emit `screen.checksum`. Client refetches `screen.full` if its computed hash differs.
6. Idle adaptation: if no input from this device for 1.5 s, drop fps to 5 Hz; restore 15 Hz on next input.
7. Overall cap: 30 Hz per surface, 60 Hz per device across all surfaces.

### 6.5 Input

`surface.send_text` carries raw text (newline included). `surface.send_key` carries a string in cmux's existing key vocabulary (`enter`, `tab`, `up`, `ctrl+c`, `esc`, …). The client encodes once via `SharedKit/KeyEncoder`.

Echo: no client-side optimistic echo; we rely on server diff. Visible feedback for the user is haptic on tap (`UIImpactFeedbackGenerator.light`).

## 7. Authentication and identity

Decision: **Tailscale identity only**. No pairing UI, no OOB code.

### 7.1 Flow

```
iPhone first launch → tap "Connect to Mac" → WS handshake to https://<mac-host>.<tailnet>.ts.net:4399/v1/stream
Relay: tsnet.LocalClient().WhoIs(remoteAddr) → { loginName, hostname, os, nodeKey }
Relay: if loginName ∈ relay.json.allow_login → accept
Relay: device_id = sha256(nodeKey); ensure record in relay.json
Relay: issue device_token (32-byte random, stored in Keychain on phone)
Relay: send macOS notification "iPhone15-Pro registered (revoke from menu bar)"
Phone: stores device_token in Keychain (Secure Enclave bound)
```

### 7.2 Defenses

| Layer | Mechanism |
|---|---|
| Network | Tailscale ACL — must be in tailnet |
| Identity | tsnet WhoIs + `allow_login` allow-list |
| TLS | `tailscale cert` or self-signed; phone pins SPKI obtained on first connect |
| Token | 32-byte random, stored as argon2id hash on relay; raw token only in phone Keychain |
| Revocation | Menu-bar app "Devices" list; or remove Tailscale node |
| Phone hardening | IOSSecuritySuite — on jailbreak/debug detection wipe Keychain |
| Rate limit | 100 send_text/s, 200 send_key/s per device → 429 + 1 s backoff |

### 7.3 relay.json (per-Mac config)

```json
{
  "listen": "0.0.0.0:4399",
  "allow_login": ["hyuni2020@gmail.com"],
  "apns": {
    "key_path": "~/.cmuxremote/apns-AuthKey.p8",
    "key_id": "ABC123XYZ",
    "team_id": "TEAM12345",
    "topic":  "com.genie.cmuxremote",
    "env":    "prod"
  },
  "snippets": [
    { "label": "git st", "text": "git status\n" },
    { "label": "ll",     "text": "ls -alh\n" }
  ],
  "default_fps": 15,
  "idle_fps":    5
}
```

Hot reload via `SIGHUP` or menu-bar "Reload" — open WS sessions are not torn down.

## 8. APNs notification flow

```
cmux notification.created
  └─▶ events.stream (relay holds 1 persistent subscription)
        └─▶ EventForwarder (filter by allowed categories)
              └─▶ for each device with apns_token:
                    APNsClient → api.push.apple.com (HTTP/2, JWT signed by .p8)
                      └─▶ iPhone NSE
                            └─▶ enrich title/subtitle with workspace name
                                  └─▶ deliver to UNUserNotificationCenter
```

### 8.1 Payload

```json
{
  "aps": {
    "alert": { "title": "Build done", "subtitle": "ws/frontend", "body": "✅ tests green" },
    "thread-id": "ws-<workspace_id>",
    "sound": "default",
    "mutable-content": 1,
    "interruption-level": "active"
  },
  "cmux": {
    "kind": "notification.created",
    "workspace_id": "...",
    "surface_id":   "...",
    "notification_id": "..."
  }
}
```

### 8.2 Tap routing

Notification tap → app launches → deep link `cmux://surface/<surface_id>` → `WorkspaceView` opens that surface. If app is already foreground, NSE simply emits an in-app banner (no relaunch).

### 8.3 Auth and rotation

- APNs JWT is signed locally with `.p8` key from `relay.json.apns.key_path`.
- Token refresh every ~50 minutes (Apple TTL is 60 minutes).
- On `BadDeviceToken` error: relay marks `apns_token` as null on that device record and stops sending until phone re-registers.
- `scripts/apns-key-rotate.sh`: revokes current key in Apple Developer, prompts for new `.p8`, atomically swaps.

## 9. iOS UX

Three primary screens plus modals.

### 9.1 Screens

```
WorkspaceListView (tab 1)
  - rows: each workspace + surface count + recent activity
  - "+ New Workspace" → workspace.create modal
WorkspaceView
  - top: back button + workspace name (tap → drawer)
  - middle: horizontal Surface tab strip
  - body: TerminalView (selected surface)
  - bottom: AccessoryBar (UIInputView)
NotificationCenterView (tab 2)
  - reverse-chronological 200 entries, grouped by thread-id
  - tap row → deep link to source surface
SettingsView (tab 3)
  - Mac connection status, snippet management (read-only in v1.0; v1.1 editor)
  - device info, "disconnect this device"
Modals
  - WorkspaceCreateView, NotificationDetailView
```

### 9.2 AccessoryBar (`UIInputView` based)

Layout follows Blink's `KBLayout` pattern (left / scrollable middle / right):

| Section | Keys (v1.0) |
|---|---|
| left   | `esc`, `ctrl`, `alt`, `arrows` (single-key 4-direction) |
| middle | `tab`, `~` `\`` `, `@` `#`, `/` `?`, `\|` `:`, snippets from `relay.json` |
| right  | `↓` (dismiss keyboard) |

`KeyTraits` `OptionSet` mirrors Blink's `KBTraits` (e.g. `.default - .portrait` to mean landscape-only). View recycling is diff-based on trait change.

`ArrowsKeyView`:
- A single key whose body shows four chevrons.
- `touchesBegan` records `_touchFirstLocation`; subsequent `touchesMoved` resolves the active quadrant.
- After 0.5 s held, repeat timer fires every 0.1 s. Each fire calls `keyDelegate.send(.up/.down/.left/.right)` and `UIDevice.current.playInputClick()`.

`NumberPickerKeyView` (deferred to v1.1): same gesture machinery but emits 0–9 via vertical drag.

### 9.3 Workspace switcher

- Hamburger top-left → side drawer (`NavigationSplitView` `.prominentDetail`).
- Edge-swipe from left edge opens drawer.
- Drawer shows workspace tree; tapping a surface deep-links into it.
- BT keyboard shortcuts: `cmd+1` … `cmd+9` select workspace by index; `cmd+[` / `cmd+]` cycle surfaces — handled by `CommandHUD` overlay (Blink `CommandsHUDView` pattern).

### 9.4 TerminalView (rendering)

- SwiftUI `Canvas` over a fixed monospaced grid (`SF Mono` 13 pt by default).
- Cells store `Character` + ANSI attribute (fg, bg, bold, underline). Updated by applying incoming `screen.diff` ops.
- ANSI parser: only the subset cmux's `surface.read_text` is known to emit (SGR sequences). Unhandled escapes are dropped silently.
- Tap on terminal area: focuses hidden `UITextField`, raises keyboard + AccessoryBar.
- Pinch to zoom font size; remembered per workspace.

## 10. Error handling and reconnect

| Situation | Phone behavior | Relay behavior |
|---|---|---|
| Tailscale flap | Exponential backoff reconnect (1s→2s→5s→10s, max 30s); top banner "Reconnecting…" | DiffEngine pauses on WS close; on reconnect with same device_id, rev cursor restored |
| App backgrounded ≤ 30 s | Keep WS, ping every 15 s | Normal |
| App backgrounded > 30 s | Drop WS; rely on APNs | Pause DiffEngine; keep events.stream subscription |
| Phone lock then unlock | Auto-reconnect; request fresh `screen.full` | Normal |
| cmux restart (boot_id change) | Invalidate surface ids; refresh workspace list; toast "cmux restarted" | Detect events.stream `boot_id` change; broadcast `reset` to all clients |
| Mac sleep | Same as Tailscale flap; show "Mac asleep — wake from another device" hint | n/a |
| Relay crash | Reconnect | launchd `KeepAlive=true` restarts; on start, re-subscribe to events.stream |

Latency targets (Tailscale LAN/regional):

- Input ack: P50 ≤ 80 ms, P95 ≤ 200 ms
- Diff frame: P50 ≤ 100 ms after underlying surface change, P95 ≤ 300 ms
- Cold APNs delivery: best-effort (Apple-controlled), typically 1–3 s

## 11. Test strategy

| Layer | Tooling | What it asserts |
|---|---|---|
| `SharedKit` | swift-testing | JSON-RPC encode/decode round-trips; `DiffOp.apply` is inverse of `compute`; KeyEncoder table |
| `DiffEngine` | swift-testing + golden fixtures | 30 ANSI scenarios (vim insert, ls colors, htop refresh) → expected `DiffOp` sequence |
| `CMUXClient` | XCTest + `socketpair` mock | All v1 cmux methods called once + error paths |
| `RelayCore` | XCTest + ephemeral cmux mock + tsnet WhoIs mock | Session lifecycle, rate limiter, rev consistency on reconnect, EventForwarder fanout |
| APNs sender | apns mock + 1 real sandbox round-trip in manual smoke | Payload shape, JWT signing, `BadDeviceToken` handling |
| iOS app | XCUITest + ViewInspector | Home → workspace → input round-trip; AccessoryBar key map; ArrowsKeyView gesture; deep link |
| E2E | Manual on Mac + simulator at end of each milestone | Workspace create / send command / receive notification |

Banned: tests that grep cmux source, tests that only check Info.plist contents, snapshot-of-source tests. Every test must exercise an executable code path.

CI: deferred. Local `swift test` and `xcodebuild test` until v1 ships.

## 12. Operational concerns

### 12.1 launchd

`~/Library/LaunchAgents/com.genie.cmuxremote.plist` with:

- `RunAtLoad=true`, `KeepAlive=true`
- `StandardOutPath=~/.cmuxremote/log/stdout.log`, `StandardErrorPath=~/.cmuxremote/log/stderr.log`
- `EnvironmentVariables`: `CMUX_SOCKET_PATH=/tmp/cmux.sock`
- `ProgramArguments`: `["~/.cmuxremote/bin/cmux-relay", "serve", "--config", "~/.cmuxremote/relay.json"]`

`scripts/install-launchd.sh` writes the plist and runs `launchctl bootstrap gui/$(id -u)`.

### 12.2 cmux socket access

Default socket path on macOS is `~/Library/Application Support/cmux/cmux.sock` (override: `CMUX_SOCKET_PATH` env). Relay runs as the same user as cmux, so default `cmuxOnly` access mode is sufficient — owner-only `srw-------` permissions gate the socket and no auth handshake is required for in-user connections. If the user runs the relay before cmux is launched, the relay returns HTTP 503 to phones and retries connect every 2 s.

Auth handshake (only required when `socketControlMode != cmuxOnly` or when running as a different user):
- Send `auth <password>\n` as the FIRST text command after connect.
- Resolution order matches cmux CLI: `--password` flag → `CMUX_SOCKET_PASSWORD` env → `~/Library/Application Support/cmux/socket-control-password` file → Keychain service `com.cmuxterm.app.socket-control` (account `local-socket-password`).
- Skip handshake entirely when password resolution returns nil — the cmux CLI itself does this.

### 12.3 Mac sleep

cmux + relay both stop when the Mac sleeps. Documented in README: for "always reachable from phone" the user runs `caffeinate -dimsu` or sets a Power schedule. We do not enable caffeinate automatically.

## 13. MVP scope (v1.0)

MUST:

- Tailscale-only auth, auto device registration
- workspace list/create/select/close
- surface list/select/send_text/send_key (incl. special keys)
- Polling + diff streaming (15 Hz, idle 5 Hz)
- AccessoryBar with esc/ctrl/alt/arrows + tab + ~10 fixed symbol keys
- ArrowsKeyView (press-and-drag 4-direction with key repeat)
- APNs push: cmux notifications → phone lock-screen
- NotificationCenter screen
- Workspace drawer
- launchd auto-start on Mac
- Menu-bar app with Devices list + revoke

LATER (v1.1+):

- AccessoryBar editor UI for snippets
- NumberPickerKeyView
- Browser surface mirroring
- iPad layout
- Handoff-style cmux notify deep link from Mac to iPhone
- Add `surface.subscribe_output` byte-stream RPC to the cmux fork (option B), enabling true tmux-grade rendering

EXPLICITLY OUT of v1.0:

- Tailscale Funnel / public exposure
- Multiple users
- E2E encryption beyond what Tailscale already provides
- Perfect TUI rendering (vim, htop) — limited by polling

## 14. Open questions (to resolve during plan/implementation)

- Exact menu-bar app: bundled inside `cmux-relay` (LSUIElement) or separate binary? — **resolved 2026-05-09:** single binary, `LSUIElement` set at runtime via `NSApp.setActivationPolicy(.accessory)`.
- AccessoryBar live-config: file watch on `relay.json` snippets vs explicit reload — **resolved 2026-05-09:** `DispatchSource.makeFileSystemObjectSource` + SIGHUP fallback.
- Whether to include a tiny config UI on the menu bar app for `allow_login` — **resolved 2026-05-09:** read-only in v1.0; edits via manual `relay.json` change + `kill -HUP` or "Reload" menu-bar action.
- Sandbox vs prod APNs default — sandbox during dev, prod after first TestFlight.

### Known issue (M2 live smoke 2026-05-10)

The cmux v2 socket `workspace.list` response contains workspace records whose actual fields are `ref` (string ref like `workspace:1`), `title`, `index`, `selected`, `current_directory`, `remote`, etc. The original section 6.3 mapping assumed our `Workspace { id, name, surfaces, lastActivity }` Codable model would round-trip with cmux's response — it does not.

**Resolution path** (M3 / relay-side):

1. Capture a representative `workspace.list` response via `cmux rpc workspace.list` and check it into `docs/specs/cmux-payload-samples/`.
2. Either (a) introduce a `CMUXWorkspaceRaw` struct in `CMUXClient` that mirrors cmux's actual schema and a translator that maps it to `SharedKit.Workspace`, or (b) revise `SharedKit.Workspace` to match cmux directly (adopt `ref` as id, rename `name`→`title`, etc.).
3. Re-run `CMUX_LIVE=1 swift test --filter LiveSocketSmokeTests` to confirm the schema is aligned.

For M2's purposes the relay-internal types remain as designed; the live smoke test demonstrates connection + envelope decoding is correct. Schema reconciliation lands in M3 task 9 (or earlier as a hot patch if M3 needs the typed decode immediately).

## 15. Quality bar

"Blink-grade keyboard + Termius-grade pairing/security + cmux-as-it-is workspace model." If any of those three weakens during implementation, stop and reconsider before continuing.
