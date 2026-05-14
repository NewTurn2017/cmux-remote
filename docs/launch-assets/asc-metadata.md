# App Store Connect — Metadata Draft (v1.0)

App: **Cmux Remote** · Bundle ID `com.genie.CmuxRemote` · Team `2UANJX7ATM`

This file is the source of truth for ASC strings. Copy-paste into ASC, do not retype.

---

## Pricing & Availability

| Field | Value |
|---|---|
| Price tier | **Free** (Tier 0) |
| Availability | All territories |
| Pre-orders | No |

## Categories

- **Primary**: Developer Tools
- **Secondary**: Productivity

## Age rating

- **4+** — no objectionable content, no ads, no in-app purchases (v1.0), no UGC.

## Routing app coverage

- N/A (not a navigation app).

---

## English — Primary localization (en-US)

### Name (max 30)

```
Cmux Remote
```
*(11 chars)*

### Subtitle (max 30)

```
Your Mac terminal, on iPhone
```
*(28 chars)*

### Promotional Text (max 170, can change without review)

```
Run claude-code, lazygit, vim, or any cmux workspace on your Mac while you are away — straight from your iPhone, over your own Tailscale network. No third-party servers.
```
*(168 chars)*

### Keywords (max 100, comma-separated, no spaces after commas)

```
cmux,terminal,ssh,tmux,tailscale,mac,remote,developer,claude,codex,wireguard,relay
```
*(82 chars)*

### Description (max 4000)

```
Cmux Remote turns your iPhone into a remote head for the cmux terminal multiplexer running on your own Mac. Connect over your Tailscale network — your traffic never touches a third-party server.

WHAT IT IS

Cmux (https://cmux.com) is a modern terminal multiplexer for macOS with native splits, workspaces, and rich integrations for AI agents like Claude Code, Codex, and Cursor. Cmux Remote mirrors the cmux surface you choose, lets you type into it, send keys, and receive notifications — all from your iPhone.

WHO IT IS FOR

- Developers who run long-lived agents (claude-code, codex, omx) on their Mac and want to peek in or nudge them from the couch
- People who SSH into their own Mac dev box from cafés today and want a less awkward experience
- Anyone already using Tailscale and looking for a private way to reach their terminal

HOW IT WORKS

1. Install the open-source `cmux-relay` binary on your Mac (one-line installer).
2. Make sure your Mac is on Tailscale.
3. Open this app, type your Mac's Tailscale hostname, and tap Connect.
4. Your cmux workspaces appear. Pick a surface and you are in.

The relay speaks directly to cmux's local Unix socket. The iPhone speaks to the relay over a WireGuard-encrypted Tailscale tunnel. Nothing leaves your network.

FEATURES

- Live mirror of cmux terminal surfaces with ANSI color and Korean / CJK width support
- Full keyboard accessory bar — Esc, Enter, Tab, arrows, Ctrl combos
- Mouse passthrough toggle (xterm SGR) for Textual / Bubble Tea / fzf TUIs
- Local push for cmux notifications (no remote APNs needed in v1.0)
- Multiple workspaces and surfaces with chip-bar switching
- Pinch-to-zoom font, scroll-to-bottom on surface change
- Demo Mode with fully populated fake data — try the app before you set up a relay

PRIVACY

No analytics. No advertising. No third-party SDKs. The bearer token your relay issues is stored only in your iOS Keychain. Read the full policy and source code at:

https://github.com/NewTurn2017/cmux-remote

REQUIREMENTS

- macOS Mac running cmux 0.64 or later
- Both Mac and iPhone signed in to the same Tailscale tailnet
- iOS 17 or later

This app is open source under the MIT license. Issues and pull requests welcome.
```

### Support URL

```
https://github.com/NewTurn2017/cmux-remote/issues
```

### Marketing URL (optional)

```
https://github.com/NewTurn2017/cmux-remote
```

### Privacy Policy URL

```
https://github.com/NewTurn2017/cmux-remote/blob/main/PRIVACY.md
```

### Copyright

```
© 2026 Cmux Remote contributors. MIT licensed.
```

---

## Korean — Secondary localization (ko)

### 이름 (max 30)

```
cmux Remote
```

### 부제 (max 30)

```
주머니 속 Mac 터미널 원격 제어
```
*(17 chars)*

### 프로모션 텍스트 (max 170)

```
Mac에서 돌아가는 claude-code, lazygit, vim, cmux 워크스페이스를 자리 비울 때도 iPhone에서 그대로 — 본인 Tailscale 네트워크 위에서. 외부 서버 거치지 않습니다.
```
*(124 chars)*

### 키워드 (max 100)

```
cmux,터미널,터미널원격,tmux,tailscale,개발자,맥,원격,claude,codex,wireguard,relay,코딩
```
*(80 chars — Korean keyword bytes count carefully, ASC limits chars not bytes)*

### 설명 (max 4000)

```
cmux Remote는 iPhone을 본인 Mac에서 돌아가는 cmux 터미널 멀티플렉서의 원격 헤드로 만들어 줍니다. Tailscale 네트워크 위에서 작동하므로 트래픽이 외부 서버를 거치지 않습니다.

이 앱이 무엇인가요

cmux (https://cmux.com)는 native splits, 워크스페이스, Claude Code / Codex / Cursor 같은 AI 에이전트와의 깊은 통합을 제공하는 macOS용 현대적 터미널 멀티플렉서입니다. cmux Remote는 선택한 cmux surface를 미러링하고, 키 입력을 보내고, 알림을 받게 해 줍니다 — 전부 iPhone에서.

누구를 위한 앱인가요

- claude-code, codex, omx 같은 장시간 에이전트를 Mac에서 돌리며, 소파에서 잠깐 들여다보거나 살짝 조작하고 싶은 개발자
- 이미 카페에서 Mac 개발 머신에 SSH 접속하는 분들 — 더 깔끔한 경험을 원할 때
- Tailscale을 이미 쓰고 있고, 터미널 접근을 위한 사설 경로를 찾고 있는 분

어떻게 작동하나요

1. Mac에 오픈소스 cmux-relay 바이너리를 설치 (한 줄 설치 스크립트 제공).
2. Mac이 Tailscale에 연결되어 있는지 확인.
3. 이 앱을 열고 Mac의 Tailscale 호스트명을 입력해 Connect 탭.
4. cmux 워크스페이스가 나타납니다. surface를 선택하면 끝.

릴레이는 Mac에서 cmux의 로컬 Unix socket과 직접 통신합니다. iPhone은 Tailscale의 WireGuard 암호화 터널을 통해 릴레이와 통신합니다. 본인 네트워크 밖으로 나가는 데이터는 없습니다.

주요 기능

- ANSI 색상 + 한국어 / CJK 폭 처리 지원하는 cmux 터미널 surface 라이브 미러
- 전용 키보드 액세서리 바 — Esc, Enter, Tab, 방향키, Ctrl 조합
- 마우스 패스스루 토글 (xterm SGR) — Textual / Bubble Tea / fzf TUI 호환
- cmux 알림용 로컬 푸시 (v1.0에서는 원격 APNs 불필요)
- 다중 워크스페이스 / surface, 칩바 전환
- 핀치 줌 폰트 사이즈, surface 전환 시 자동 하단 스크롤
- 데모 모드 — 릴레이 설정 전에도 가짜 데이터로 앱을 둘러볼 수 있음

개인정보 처리

분석 도구 없음. 광고 없음. 서드파티 SDK 없음. 릴레이가 발급하는 bearer 토큰은 iOS Keychain에만 저장됩니다. 전체 정책과 소스 코드:

https://github.com/NewTurn2017/cmux-remote

요구 사양

- cmux 0.64 이상이 설치된 macOS Mac
- Mac과 iPhone 모두 같은 Tailscale tailnet에 로그인되어 있을 것
- iOS 17 이상

이 앱은 MIT 라이선스로 공개된 오픈소스입니다. Issues와 pull requests 환영.
```

### 저작권

```
© 2026 cmux Remote 기여자들. MIT 라이선스.
```

---

## App Privacy ("Data Used to Track You" / "Data Collected")

| Question | Answer |
|---|---|
| Does this app collect data? | **No** |
| Is data linked to user identity? | N/A |
| Is data used to track? | N/A |
| Third-party SDKs? | None |

The app stores `bearer` and `device_id` in the iOS Keychain, but these are issued by the **user's own** Mac relay and never sent to any developer-controlled server. Per Apple's definition this is not "data collection".

## Encryption / Export Compliance

| Field | Value |
|---|---|
| `ITSAppUsesNonExemptEncryption` (Info.plist) | `false` |
| Reasoning | App uses only Apple's standard cryptography (Keychain, URLSession TLS where present) and relies on Tailscale (third-party transport encryption). No proprietary encryption. Auto-exempt. |

## App Tracking Transparency (ATT)

Not used in v1.0. No advertising identifiers, no tracking. (Required only when v1.1 adds AdMob.)

## App Review Notes

Paste this verbatim into the **App Review Information → Notes** field:

```
Cmux Remote is a remote-control client for the cmux Mac terminal multiplexer over the user's own Tailscale network. App Review cannot replicate this setup because it requires a Mac running cmux + cmux-relay on a tailnet only the user controls.

To evaluate the full app:
1. Launch the app.
2. Tap the Settings tab (gear icon at the bottom).
3. Find the "demo mode" section near the top.
4. Tap [ TRY DEMO MODE ].
5. The app re-bootstraps with simulated workspaces, terminal output, and notifications. A yellow "DEMO" badge appears in the workspace header.

In demo mode you can:
- See two demo workspaces (mybest-edu-ai, cmux-remote)
- Open four demo surfaces (Claude Code session, shell, swift test, relay log)
- Tap arrow keys / Esc / Tab — they no-op safely
- Open the Inbox tab to see two demo notifications
- Toggle demo mode off via the same Settings button

The app has zero data collection, no analytics, no third-party SDKs, no advertising. Full source code: https://github.com/NewTurn2017/cmux-remote

Local network usage description (NSLocalNetworkUsageDescription) is required because the relay listens on a Tailscale-assigned IP. Tailscale already provides WireGuard transport encryption, so the relay's HTTP+WS protocol is safe over that tunnel. NSAllowsArbitraryLoads = true is set for the same reason.

Please contact via GitHub Issues if anything is unclear:
https://github.com/NewTurn2017/cmux-remote/issues
```

## Demo account

- **Username**: `(none — Demo Mode requires no login)`
- **Password**: `(none)`
- **Notes**: See App Review Notes above.

---

## Screenshot manifest

Source: `docs/launch-assets/screenshots/app-store-6.9/`

| # | File | Caption (EN) | 자막 (KR) |
|---|---|---|---|
| 1 | `01-workspaces-remote-control.png` | All your cmux workspaces, one tap away | 모든 cmux 워크스페이스, 한 번에 |
| 2 | `02-terminal-live-control.png` | Live terminal with full keyboard | 라이브 터미널 + 전용 키보드 |
| 3 | `03-keyboard-shortcuts.png` | Esc, Tab, arrows, Ctrl combos built in | Esc · Tab · 방향키 · Ctrl 조합 내장 |
| 4 | `04-inbox-notifications.png` | Local push for every cmux event | cmux 이벤트 로컬 푸시 |
| 5 | `05-settings-connection-guide.png` | Built-in setup walkthrough | 설치 가이드 내장 |

Sizes needed:
- ✅ 6.9" (1320×2868) — have 5
- ⚠️ 6.5" (1284×2778) — Apple auto-scales from 6.9", but recommended to provide native captures
- ⚠️ 6.7" (1290×2796) — same

App previews (video): not required for v1.0.

## Localization checklist

| Locale | App Name | Subtitle | Description | Keywords | Screenshots |
|---|---|---|---|---|---|
| en-US (primary) | ✅ | ✅ | ✅ | ✅ | ⚠️ rebuild captions in EN |
| ko (secondary) | ✅ | ✅ | ✅ | ✅ | ✅ already in KR |

## Submission checklist

- [ ] Apple Developer Program active ($99/yr)
- [ ] App registered in App Store Connect with bundle id `com.genie.CmuxRemote`
- [ ] Demo Mode verified to work in Release build
- [ ] `ITSAppUsesNonExemptEncryption=false` in Info.plist (✅ done)
- [ ] PRIVACY.md committed and accessible at the URL above (✅ done)
- [ ] App Review Notes pasted from this document
- [ ] Both en-US and ko metadata filled in
- [ ] Screenshots uploaded for at least 6.9"
- [ ] In-App Purchases: none (v1.0)
- [ ] Build archived with Release config + Distribution provisioning profile
- [ ] Build uploaded via Xcode → Organizer → Distribute App → App Store Connect
- [ ] TestFlight internal test passes (recommended before public submit)
- [ ] Submit for Review
