[🇰🇷 한국어](README.md) · 🇺🇸 English

# cmux Remote

> Unofficial iPhone remote for [cmux](https://github.com/manaflow-ai/cmux)
> on your Mac, over Tailscale.

cmux Remote is a SwiftUI app + Swift daemon pair that lets you read and
drive the terminals running inside cmux on your Mac, from anywhere on
your Tailscale tailnet. No port is ever exposed to the public internet
— every byte travels over your existing WireGuard mesh.

This is a community project and is **not** built or endorsed by
Manaflow. cmux Remote is an independent network client that talks to
cmux exclusively over a documented JSON-RPC protocol.

---

## Status

**Early preview (v1.0).** It can:

- list, open, create, and close cmux workspaces and surfaces
- mirror any terminal surface in near real-time (15 Hz diff polling)
- send keystrokes, key combinations, raw text, and command lines
- surface cmux notifications as iOS local notifications (while the app
  is alive)
- pass through taps as xterm SGR mouse events for TUIs that opted in
  (Textual / Bubble Tea / fzf / omx menus)
- pin cmux pane focus on every send, plus a "previous pane" toggle for
  agents that shell out to sub-panes

Smoke-tested against macOS 14 + iOS 17 on both LAN and across a Tailnet
(Tailscale 1.84+), on simulator and a physical iPhone.

> **Notification caveat** — current notifications are *local*: iOS
> banners only fire while the app is foregrounded, or while it's still
> alive in the background with an open WebSocket. True APNs push (so
> banners arrive when the app is killed or has been backgrounded for a
> long time) is on the v1.1 roadmap.

## Screenshots

<p align="center">
  <img src="docs/launch-assets/source/cmux-remote-brandmark-transparent.png" alt="cmux Remote brandmark" width="320">
</p>

<table>
  <tr>
    <td align="center" width="20%"><img src="docs/launch-assets/screenshots/app-store-6.9/01-workspaces-remote-control.png" alt="Workspace remote control" width="180"><br><sub>Workspace / surface chip bar</sub></td>
    <td align="center" width="20%"><img src="docs/launch-assets/screenshots/app-store-6.9/02-terminal-live-control.png" alt="Terminal live control" width="180"><br><sub>Live terminal mirror</sub></td>
    <td align="center" width="20%"><img src="docs/launch-assets/screenshots/app-store-6.9/03-keyboard-shortcuts.png" alt="Key accessory bar" width="180"><br><sub>Key accessory bar</sub></td>
    <td align="center" width="20%"><img src="docs/launch-assets/screenshots/app-store-6.9/04-inbox-notifications.png" alt="Inbox notifications" width="180"><br><sub>Notification Inbox</sub></td>
    <td align="center" width="20%"><img src="docs/launch-assets/screenshots/app-store-6.9/05-settings-connection-guide.png" alt="Settings · pairing" width="180"><br><sub>Settings · pairing guide</sub></td>
  </tr>
</table>

---

## Why?

cmux is a fantastic Mac-native terminal for AI coding agents, but the
moment you walk away from your desk it goes dark. cmux Remote gives you
a thin glass pane onto the same workspaces while you're on the couch,
on a train, or debugging from a coffee shop. The Mac is still doing all
the work — the iPhone is just a remote.

---

## Architecture

```
iPhone (iOS 17+)         Tailscale            Mac
┌─────────────────────┐                       ┌────────────────────────────────┐
│ cmux Remote (app)   │── HTTP + WS ─────────▶│ cmux-relay (Swift, launchd)    │
│  · workspace list   │   (Tailscale encrypts)│  · HTTP/1.1 routes             │
│  · terminal mirror  │                       │  · /v1/stream WebSocket        │
│  · accessory bar    │◀── events.stream ─────│  · DiffEngine (15 Hz polling)  │
│  · local notifs     │                       │  · Tailscale whois auth        │
└─────────────────────┘                       │  · device tokens + rate limit  │
                                              └─────────────┬──────────────────┘
                                                            │ Unix socket
                                                            │ JSON-RPC
                                                            ▼
                                              ┌────────────────────────────────┐
                                              │ cmux.app                       │
                                              │ ~/Library/Application Support/ │
                                              │   cmux/cmux.sock               │
                                              └────────────────────────────────┘
```

Two pieces to install:

1. **`cmux-relay`** — a small Swift daemon on the same Mac as cmux. It
   speaks JSON-RPC to cmux's local Unix socket and exposes an HTTP +
   WebSocket API on your tailnet interface. TLS is provided by the
   Tailscale WireGuard transport itself.
2. **cmux Remote (iOS)** — the SwiftUI app on your iPhone. It only
   talks to your own relay; nothing ever leaves your tailnet.

This repo deliberately ships **no** cmux source code. It is a network
client that talks to cmux over a documented JSON-RPC schema.

---

## Features

### Workspaces / surfaces

- Workspace and terminal-surface listing
- In-app surface create / close from the chip bar (with confirmation
  dialog and automatic fallback selection)
- Auto re-subscribe and bottom-pin on workspace / surface switch
- First-RPC gate (`CMUXClient.awaitReady`) so the inbound bridge is
  installed before any call goes out

### Terminal mirror

- 15 Hz diff polling, full-text fallback, checksum-based reconcile
- Pinch-to-zoom (8–32 pt) with a smooth anchor-preserving response
- Tokyo Night Storm ANSI palette plus a CRT scanline shader
- Correct East-Asian wide-glyph cell width
- Suppresses iOS auto-promotion of glyphs like ● ⏺ ✔ ▶ to color emoji
  (Variation Selector-15 plus a small substitution table)

### Input

- Accessory bar: `esc` `↵` `⇧↵` `/` `$` `tab` `← ↑ ↓ →` `ms` `↺p`
- Command composer with text + enter as one shot, plus modifier
  toggles
- `surface.send_key` is delivered via an `NSEvent` synth on the Mac
  side, so multi-byte sequences (arrows, ctrl-combos) arrive
  atomically — important for Ink-based TUIs (Claude Code etc.) whose
  ESC parser fires on a lone ESC byte if the rest of the sequence is
  even a few ms behind.
- **Focus gate** — every subscribe, resubscribe, and every `sendKey`
  re-pins `surface.focus` first. iPhone keys land on the surface you
  intended even after focus moved at the Mac.
- **Pane toggle (`↺p`)** — jumps to the previously focused cmux pane.
  Useful when omx (or any agent that shells out to a raw-mode prompt
  in a sibling pane) is the actual stdin target. Falls back from
  `pane.last` to `pane.list` + `pane.focus`.
- **Mouse passthrough (`ms`)** — when toggled, taps on the terminal
  emit xterm SGR press/release escapes via `surface.send_text`. Works
  with Textual, Bubble Tea, fzf, omx menus — anything that opted into
  mouse mode.

### Notifications

- Surfaces cmux `events.stream` notifications as iOS local
  notifications via `UNUserNotificationCenter`, grouped per workspace
  by `threadIdentifier`
- Authorization is requested lazily, pre-warmed once at app launch
- Duplicate-id guard — a reconnect that re-emits the same notification
  only fires one banner
- Inbox view holds the most recent 200 entries (newest first)
- Deep link `cmux://surface/<id>` (will be joined by APNs payload
  routing in M6)
- `SEND TEST NOTIFICATION` button in Settings: a local inject for
  immediate Inbox/banner confirmation, plus a separate status line for
  the relay→cmux→events.stream round-trip

### Mac relay

- HTTP/1.1 with WebSocket upgrade (`SwiftNIO`)
- JSON-RPC 2.0 dispatch
- DiffEngine — actor-based, per-device FPS budget, row-granular diffs
- Auth via Tailscale UDS `whois` (foreground service) with a GUI
  fallback
- Hashed bearer tokens per device, revocable individually from the
  menu bar
- Per-device rate limiter and `boot_id`-driven reset broadcast
- Ships as a launchd user agent, with an injected `PATH` so the
  `tailscale` CLI is reachable from a stripped launchd environment
- Dedicated cmux UDS channel for the events stream (the subscribed
  channel becomes push-only and won't accept further RPC responses)

### Security

- Relay binds to `0.0.0.0` but refuses non-Tailscale source addresses
  at the application layer (`EndpointPolicy`)
- Per-device tokens with menu-bar revoke
- Notification payloads never contain terminal contents — only a
  workspace/surface id and a short title
- No telemetry, no analytics, no third-party network calls

---

## Requirements

### Mac (the relay)

- macOS 13 Ventura or newer
- A working [cmux](https://github.com/manaflow-ai/cmux) installation
  with its Unix socket exposed (default
  `~/Library/Application Support/cmux/cmux.sock`)
- Swift 5.10 toolchain (Xcode 15.3+) to build from source
- Tailscale installed and signed in
- A free TCP port for the relay (default `4399`)

### iPhone

- iOS 17 or newer
- Same Tailnet as your Mac (Tailscale app signed in)
- Apple Developer account for sideloading (the free 7-day personal
  cert works; App Store distribution needs a paid account)

### Network

- Tailscale 1.84+ on both ends
- No Funnel, no public hostname required

---

## Quickstart

### 1. Build and install the relay on your Mac

```bash
git clone https://github.com/<you>/cmux-iphone.git
cd cmux-iphone
swift build -c release --product cmux-relay

# Install as a launchd user agent (auto-starts on login)
./scripts/install-launchd.sh
```

The installer copies the binary into `~/.cmuxremote/bin/`, renders
`~/Library/LaunchAgents/com.genie.cmuxremote.plist`, and bootstraps the
service. Logs land in `~/.cmuxremote/log/`.

Health check:

```bash
curl -s http://$(tailscale ip -4):4399/v1/health
# {"ok":true,"version":"0.1.0"}
```

Socket probe:

```bash
./scripts/cmux-probe.sh
# {"id":"probe-1","result":{...}}
```

### 2. Pair your iPhone

Open cmux Remote on the iPhone:

1. Tap **Add Mac**
2. Enter the Tailscale IP or MagicDNS name plus port `4399`
3. Approve the pairing request from the Mac's menu bar

Pairing exchanges a per-device token. Revoke any device anytime from
the menu bar.

### 3. Use it

- **Workspaces** — the workspace list. Tap one to expand its surface
  chip bar.
- **Terminal** — the tapped surface mirrors here. The bottom accessory
  bar carries esc / arrows / tab / mouse mode / pane toggle.
- **Notifications** — Inbox for cmux notifications. Anything delivered
  while the app is alive shows up newest-first, plus an iOS banner
  (foreground or short background only).
- **Settings** — host/port, reconnect, send test notification.

---

## Configuration

The relay reads `~/.cmuxremote/relay.json` (created by
`install-launchd.sh` if missing):

```json
{
  "listen":      "0.0.0.0:4399",
  "cmux_socket": "/Users/<you>/Library/Application Support/cmux/cmux.sock",
  "diff_hz":     15
}
```

`listen` is `0.0.0.0`, but non-Tailscale source addresses are refused
at the application layer regardless. To allow localhost in dev, run
the installer with `CMUX_DEV_ALLOW_LOCALHOST=1`.

> **APNs key fields (`apns_team_id`, `apns_key_id`, `apns_key_path`)
> are coming in v1.1.** Until then, cmux notifications are presented
> as iOS local notifications only — they do not reach a killed app.

---

## Roadmap

- [x] v1.0 — workspace listing, surface create/close, terminal mirror,
      keystroke send, mouse mode, pane toggle, local notifications,
      Tokyo Night Storm UI
- [ ] **v1.1 — APNs push** (alerts that arrive while the app is killed
      or long-backgrounded), payload-driven deep-link to surface
- [ ] v1.2 — iPad layout, external keyboard polish
- [ ] v1.3 — file preview for cmux's "open in pane" intents
- [ ] v2.0 — byte-stream RPC for high-rate TUIs (vim, htop, k9s)
- [ ] Maybe — Android client (PRs welcome, see `docs/specs/`)

Explicit non-goals: public-internet exposure (Tailscale Funnel),
multi-user sharing, server-side persistence beyond the live session.

---

## Project layout

```
cmux-iphone/
├─ README.md / README.en.md
├─ LICENSE
├─ docs/
│  ├─ screenshots/          # README assets
│  └─ specs/                # design docs, RFCs
├─ Package.swift            # SharedKit / CMUXClient / RelayCore / cmux-relay
├─ Sources/
│  ├─ SharedKit/            # Codable models, JSON-RPC envelope, key tables, screen hasher
│  ├─ CMUXClient/           # cmux UDS JSON-RPC client (Mac only)
│  ├─ RelayCore/            # Auth, sessions, DiffEngine, RowState, DeviceStore
│  └─ RelayServer/          # @main, NIO HTTP+WS, launchd entry point
├─ Tests/                   # unit + integration tests
├─ ios/
│  ├─ CmuxRemote.xcodeproj
│  └─ CmuxRemote/
│     ├─ CmuxRemoteApp.swift / ContentView.swift
│     ├─ Network/           # RPCClient, WSClient, AuthClient, EndpointPolicy
│     ├─ Notifications/     # LocalNotificationPresenter, NotificationCenterView
│     ├─ Stores/            # WorkspaceStore, SurfaceStore, NotificationStore
│     ├─ Terminal/          # CellGrid, ANSIParser, TerminalView, cell-width
│     ├─ Workspace/         # WorkspaceListView, WorkspaceDrawer, WorkspaceView
│     ├─ Settings/          # SettingsView
│     ├─ Keyboard/          # CommandComposer
│     ├─ UI/                # Tokyo Night theme, splash, Metal shader
│     ├─ Security/          # HardeningCheck
│     └─ Storage/           # Keychain
└─ scripts/
   ├─ install-launchd.sh    # cmux-relay launchd installer
   ├─ uninstall-launchd.sh
   ├─ relay.plist.tmpl
   ├─ cmux-probe.sh         # ping the cmux socket
   ├─ smoke-relay.sh        # end-to-end tailnet smoke
   └─ evaluate-terminal-keyboard.sh
```

> Internal identifiers use the camelCased `CmuxRemote` (Xcode target,
> Swift module names, bundle ID `com.genie.CmuxRemote`). The
> home-screen display name is **cmux Remote** with a space. Both are
> correct.

---

## Development

```bash
# Run all Swift tests (relay + shared kits)
swift test

# Generate the Xcode project for the iOS app
cd ios && xcodegen generate

# Run the iOS test suite against a fake in-process relay
xcodebuild test -project CmuxRemote.xcodeproj \
  -scheme CmuxRemote -destination 'platform=iOS Simulator,name=iPhone 15'

# Full smoke against a real cmux + real Tailscale (slow; ephemeral node)
SMOKE_EPHEMERAL=1 ./scripts/smoke-relay.sh
```

The smoke script spins up an ephemeral Tailscale node and an isolated
config dir, registers a fake device, and exercises every documented
relay endpoint (`/v1/health`, `/v1/devices/me/register`, `/v1/state`,
`/v1/devices/me/apns`, WebSocket hello, `workspace.list`,
`surface.list`, `surface.subscribe`, `screen.diff`,
`screen.checksum`). Run it any time you change the relay wire format.

The iOS app uses `FakeRPCDispatch` (default in DEBUG simulator builds,
or `FAKE_RPC=1`), so the project builds, runs, and passes UI tests
without a real relay attached.

---

## Contributing

Issues and PRs are welcome. A few ground rules:

- One feature per PR. Keep the diff small.
- Add or update tests. The relay has decent unit coverage; the iOS app
  has a fake-relay dispatch for UI tests. Don't regress either.
- Don't paste cmux source code into this repo. We deliberately keep
  this side license-clean (see below).
- Bug reports should include relay log lines and the cmux version
  (`cmux --version`).

For larger ideas (new transport, new auth model, byte-stream RPC),
open a discussion or drop a design doc under `docs/specs/` first.

---

## Security

- The relay binds to the tailnet interface only — non-Tailscale source
  addresses are refused at the application layer (the only escape
  hatch is `CMUX_DEV_ALLOW_LOCALHOST=1` for dev).
- Each iPhone is issued a per-device token at pairing time. Tokens can
  be revoked individually from the relay's menu bar.
- Notification payloads never contain terminal contents — only a
  workspace/surface id and a short title.
- No telemetry. No analytics. No third-party network calls.

If you find a security issue, please email the maintainer (see
`SECURITY.md`) instead of filing a public issue.

---

## License

cmux Remote is released under the **MIT License** — see
[`LICENSE`](LICENSE).

### Relationship to cmux

[cmux](https://github.com/manaflow-ai/cmux) is © Manaflow, Inc. and is
dual-licensed under GPL-3.0-or-later or a commercial license. cmux
Remote is an **independent network client**. It does not include, link
to, or modify any cmux source code; it communicates with cmux
exclusively over a documented JSON-RPC protocol. The Free Software
Foundation's general position is that a program that interacts with a
GPL program purely over a documented network protocol is not a
derivative work of that program, and cmux Remote is distributed on
that basis.

### Trademark notice

"cmux" is a name used by Manaflow, Inc. to identify their terminal
product. cmux Remote uses the name "cmux" only descriptively, to
identify the software this client is designed to interoperate with.
cmux Remote is not affiliated with, sponsored by, or endorsed by
Manaflow, Inc. If you're from Manaflow and would like the name
changed, please open an issue — we'll rename without argument.

---

## Acknowledgements

- The [cmux](https://github.com/manaflow-ai/cmux) team for building
  the terminal this app extends.
- [Tailscale](https://tailscale.com) for the boring-but-perfect
  transport.
- [SwiftNIO](https://github.com/apple/swift-nio) for the relay's
  HTTP/WS stack.
