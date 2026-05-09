# cmux iPhone Bridge — Implementation Plan (Master)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> This master file maps milestones to per-PR plan files. Open the relevant milestone file and execute its tasks linearly. Do not skip the master self-review at the end of each milestone.

**Goal:** Ship an iPhone-only SwiftUI client that drives the user's local cmux on Mac via Tailscale, with a Mac-local Swift relay (launchd), 15 Hz polling diff WebSocket, and APNs push.

**Architecture:** Five Swift code units in one Swift Package + one Xcode iOS project. Mac side: `SharedKit + CMUXClient + RelayCore + RelayServer`. iOS side: SwiftUI app re-using `SharedKit` as a local package dep. Wire format = JSON-RPC 2.0 over WebSocket; Tailscale-only auth via `tsnet WhoIs`. Notifications fan out to APNs.

**Tech Stack:** Swift 5.10, swift-nio, swift-nio-ssl, swift-crypto, async-http-client, libtailscale (BSD-3 via swift bindings), SwiftUI (iOS 17+), `URLSessionWebSocketTask`, IOSSecuritySuite (MIT). swift-testing on Mac side, XCTest + ViewInspector for the iOS app.

---

## 1. Source spec

`docs/specs/2026-05-09-cmux-iphone-bridge-design.md` (v1.0 Draft, locked 2026-05-09). Every task in every milestone plan must trace back to a section in that spec.

## 2. Milestone graph

```
M1 SharedKit ── M2 CMUXClient + DiffEngine ── M3 RelayServer ── M4 iOS skeleton ── M5 AccessoryBar ── M6 APNs end-to-end
   (lib)            (lib, Mac)                  (daemon)         (app)            (app)             (cross)
```

Each milestone is a single PR. PR N must not be opened until PR N-1 has merged on `main`. There is no GitHub remote in v1.0; "merge" means `git merge --ff-only` to local `main` after the milestone's exit criteria are green.

| # | File | Subject | Branch | Exit criteria |
|---|---|---|---|---|
| M1 | `2026-05-09-m1-sharedkit.md` | Repo bootstrap + SharedKit module | `m1-sharedkit` | `swift test --filter SharedKitTests` green, 100% of public types Codable round-trip |
| M2 | `2026-05-09-m2-cmux-client-diff-engine.md` | CMUXClient (Unix socket) + DiffEngine | `m2-cmux-diff` | `swift test --filter CMUXClientTests` and `--filter DiffEngineTests` green; 30 ANSI golden fixtures pass |
| M3 | `2026-05-09-m3-relay-server.md` | RelayServer (HTTP/WS, tsnet auth, launchd, menu-bar) | `m3-relay` | `swift test --filter RelayCoreTests`; manual smoke: `swift run cmux-relay serve` accepts a `wscat`-style WS handshake from a Tailscale peer |
| M4 | `2026-05-09-m4-ios-skeleton.md` | iOS app skeleton + Workspace/Terminal/Notification/Settings | `m4-ios` | XCUITest green; manual smoke on simulator: connect to a running M3 relay, list workspaces, send a command, see diff render |
| M5 | `2026-05-09-m5-accessory-bar.md` | Blink-pattern AccessoryBar + ArrowsKeyView + CommandHUD | `m5-keyboard` | XCUITest covers tap-each-key + drag-arrows + cmd+1..9 HUD; manual smoke: vim insert / cursor traversal |
| M6 | `2026-05-09-m6-apns.md` | APNs end-to-end (JWT, fanout, NSE, deep link) | `m6-apns` | sandbox APNs round-trip in manual smoke; deep link `cmux://surface/<id>` opens correct view; `BadDeviceToken` clears stale token |

## 3. Cross-cutting file map

```
~/dev/side/cmux-iphone/
├─ Package.swift                              # M1
├─ Package.resolved                           # generated
├─ Sources/
│  ├─ SharedKit/                              # M1
│  │  ├─ JSONRPC.swift
│  │  ├─ Models.swift
│  │  ├─ DiffOp.swift
│  │  ├─ KeyEncoder.swift
│  │  └─ WireProtocol.swift
│  ├─ CMUXClient/                             # M2
│  │  ├─ UnixSocketChannel.swift
│  │  ├─ CMUXClient.swift
│  │  ├─ CMUXMethods.swift
│  │  └─ EventStream.swift
│  ├─ RelayCore/                              # M2 (DiffEngine), M3 (rest), M6 (APNs)
│  │  ├─ DiffEngine.swift                     # M2
│  │  ├─ AnsiHasher.swift                     # M2
│  │  ├─ RowState.swift                       # M2
│  │  ├─ Session.swift                        # M3
│  │  ├─ SessionManager.swift                 # M3
│  │  ├─ AuthService.swift                    # M3
│  │  ├─ DeviceStore.swift                    # M3
│  │  ├─ ConfigLoader.swift                   # M3
│  │  ├─ RateLimiter.swift                    # M3
│  │  ├─ EventForwarder.swift                 # M6
│  │  ├─ APNsJWTSigner.swift                  # M6
│  │  ├─ APNsClient.swift                     # M6
│  │  └─ APNsSender.swift                     # M6
│  ├─ RelayServer/                            # M3, M6
│  │  ├─ main.swift
│  │  ├─ HTTPServer.swift
│  │  ├─ WebSocketHandler.swift
│  │  ├─ Routes.swift
│  │  └─ TSNet.swift
│  └─ MenuBarApp/                             # M3 — separate SwiftPM executable, LSUIElement bundle assembled in scripts
│     ├─ App.swift
│     ├─ AppDelegate.swift
│     ├─ DevicesWindow.swift
│     └─ StatusItemController.swift
├─ Tests/
│  ├─ SharedKitTests/                         # M1
│  ├─ CMUXClientTests/                        # M2
│  ├─ DiffEngineTests/                        # M2
│  ├─ DiffEngineFixtures/                     # M2 (resources)
│  ├─ RelayCoreTests/                         # M3, M6
│  └─ RelayServerTests/                       # M3
├─ ios/
│  ├─ CmuxRemote.xcodeproj
│  └─ CmuxRemote/
│     ├─ CmuxRemoteApp.swift                  # M4
│     ├─ ContentView.swift                    # M4
│     ├─ Network/                             # M4
│     │  ├─ WSClient.swift
│     │  ├─ AuthClient.swift
│     │  └─ RPCClient.swift
│     ├─ Storage/Keychain.swift               # M4
│     ├─ Security/HardeningCheck.swift        # M4
│     ├─ Stores/                              # M4
│     │  ├─ WorkspaceStore.swift
│     │  ├─ SurfaceStore.swift
│     │  └─ NotificationStore.swift
│     ├─ Workspace/                           # M4
│     │  ├─ WorkspaceListView.swift
│     │  ├─ WorkspaceView.swift
│     │  └─ WorkspaceDrawer.swift
│     ├─ Terminal/                            # M4
│     │  ├─ TerminalView.swift
│     │  ├─ ANSIParser.swift
│     │  └─ CellGrid.swift
│     ├─ Notifications/                       # M4
│     │  └─ NotificationCenterView.swift
│     ├─ Settings/                            # M4
│     │  └─ SettingsView.swift
│     ├─ Keyboard/                            # M5
│     │  ├─ KBLayout.swift
│     │  ├─ KeyTraits.swift
│     │  ├─ AccessoryBar.swift
│     │  ├─ ArrowsKeyView.swift
│     │  └─ CommandHUDView.swift
│     ├─ Push/                                # M6
│     │  ├─ AppDelegate+Push.swift
│     │  └─ DeepLinkRouter.swift
│  └─ CmuxRemoteNSE/                          # M6 (NotificationServiceExtension target)
│     └─ NotificationService.swift
└─ scripts/
   ├─ install-launchd.sh                      # M3
   ├─ uninstall-launchd.sh                    # M3
   └─ apns-key-rotate.sh                      # M6
```

## 4. Spec coverage map

| Spec section | Covered in |
|---|---|
| 1 Goal | M2 + M3 + M4 (workspace + surface + diff round trip) |
| 2 Non-goals | enforced by milestone scope |
| 3 High-level architecture | M1 file layout, M2/M3 wiring |
| 4 Project layout | M1 task 1 (Package.swift), M3 menu-bar, M4 ios/, M6 NSE |
| 5 External dependencies | M1 task 1 (deps in Package.swift), M3 task on tsnet, M6 task on async-http-client |
| 6.1 Endpoints | M3 Routes.swift |
| 6.2 JSON-RPC envelope | M1 JSONRPC.swift |
| 6.3 cmux RPC mapping | M2 CMUXMethods.swift + M3 WebSocketHandler dispatch |
| 6.4 DiffEngine | M2 DiffEngine + golden fixtures |
| 6.5 Input | M1 KeyEncoder + M3 send_text/send_key dispatch |
| 7 Auth + identity | M3 AuthService + DeviceStore + M4 AuthClient |
| 7.2 Defenses (rate limit) | M3 RateLimiter |
| 7.3 relay.json | M3 ConfigLoader |
| 8 APNs flow | M6 EventForwarder + APNsSender + NSE |
| 9.1 Screens | M4 |
| 9.2 AccessoryBar | M5 |
| 9.3 Workspace switcher | M4 (drawer) + M5 (CommandHUD) |
| 9.4 TerminalView rendering | M4 TerminalView + ANSIParser |
| 10 Error / reconnect | M4 reconnect, M3 boot_id reset broadcast, M5 not affected |
| 11 Test strategy | each milestone has explicit test task |
| 12.1 launchd | M3 |
| 12.2 cmux socket access | M2 (503 path) + M3 (start-up gate) |
| 13 MVP scope | covered across M1–M6 |
| 14 Open questions | resolved inline within affected milestones |

## 5. Working agreements

- Branch from `main` per milestone. After exit criteria green, `git merge --ff-only` then archive the branch.
- Commits are small (≤ 200 LoC diff). Every code-changing step ends with `git add ... && git commit -m ...`.
- TDD red → green → refactor for every behavioral change. Pure code moves are commit-only (no test).
- No `// TODO` left in code at milestone close. Open questions go in the milestone plan's "Deferred" list.
- Banned by spec section "Test strategy": grepping cmux source, snapshot-of-source tests, Info.plist-only assertions.
- No GitHub remote in v1.0. Local main only.

## 6. How to run a milestone

1. Read this master file + the target milestone plan front-to-back.
2. `git checkout -b mN-<slug>` from `main`.
3. Walk tasks top-to-bottom. Mark each step with `- [x]` as you complete it.
4. At the end, run the milestone's "Exit criteria" section verbatim and paste output into the PR description (or commit body, since no remote yet).
5. Self-review against spec coverage table above. If a row touched by this milestone is missing, fix before merge.
6. `git checkout main && git merge --ff-only mN-<slug>`.
7. Open the next milestone plan.

## 7. Deferred (intentionally out of v1.0)

Tracked here so they don't leak into milestone task lists:

- TestFlight / App Store distribution
- iCloud sync of snippets
- iPad layout
- Tailscale Funnel
- byte-stream surface output (cmux fork option B)
- AccessoryBar editor UI for snippets

---

## 8. Execution

Plan complete. Pick up M1 (`2026-05-09-m1-sharedkit.md`) to start.
