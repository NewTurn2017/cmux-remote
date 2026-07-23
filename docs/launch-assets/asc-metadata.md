# App Store Connect — Metadata Draft (v1.0.8 build 10)

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
Private terminal companion
```
*(26 chars)*

### Promotional Text (max 170, can change without review)

```
LIVE per-character input, a Ctrl-C key, and quieter notifications that ping you only when an agent needs input. Control cmux from your phone, private over Tailscale.
```
*(165 chars)*

### Keywords (max 100, comma-separated, no spaces after commas)

```
cmux,terminal,ssh,tmux,tailscale,remote,developer,claude,codex,wireguard,relay
```
*(78 chars)*

### Description (max 4000)

```
Cmux Remote is a private remote-control client for the cmux terminal multiplexer running on your own computer. Connect over your Tailscale network — your traffic never touches a third-party relay.

WHAT IT IS

Cmux (https://cmux.com) is a modern terminal multiplexer with native splits, workspaces, and rich integrations for AI agents like Claude Code, Codex, omx, and Cursor. Cmux Remote mirrors the cmux surface you choose, lets you type into it, send keys, manage workspaces, attach photos, and receive notifications — all from this mobile app.

WHO IT IS FOR

- Developers who run long-lived agents (claude-code, codex, omx) and want to peek in or nudge them from the couch
- People who SSH into their own development machine from cafés today and want a less awkward experience
- Anyone already using Tailscale and looking for a private way to reach their terminal

HOW IT WORKS

1. Install the open-source `cmux-relay` binary on the computer that runs cmux (one-line installer).
2. Make sure that computer is connected to Tailscale.
3. Open this app, type the computer's Tailscale hostname, and tap Connect.
4. Your cmux workspaces appear. Pick a surface and you are in.

The relay speaks directly to cmux's local Unix socket. This app speaks to the relay over a WireGuard-encrypted Tailscale tunnel. Nothing leaves your network.

FEATURES

- Performance-tuned live mirror of cmux terminal surfaces with Korean / CJK width support and ANSI colors when styled relay data is available
- Full keyboard accessory bar — Esc, Enter, Tab, arrows, Ctrl-C, other Ctrl combos, /new, and Space
- Keyboard-safe composer layout with automatic keyboard dismissal after submit
- Paste text from the mobile clipboard and attach photos; files are saved by the relay under Downloads/cmux-remote
- Local and native Inbox push notifications for cmux events plus AI-agent needs-input prompts
- Workspace create, rename, close, and multi-surface chip-bar switching
- Connected computer battery status when the relay can provide it
- Pinch-to-zoom font, scroll-to-bottom on surface change
- Demo Mode with fully populated fake data — try the app before you set up a relay

PRIVACY

No analytics. No advertising. No third-party SDKs. The bearer token your relay issues is stored only in the system's secure credential storage on your device. Read the full policy and source code at:

https://github.com/NewTurn2017/cmux-remote

REQUIREMENTS

- A personal computer running cmux 0.64 or later and cmux-relay
- Both devices signed in to the same Tailscale tailnet
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
사설 터미널 원격 제어
```
*(12 chars)*

### 프로모션 텍스트 (max 170)

```
이제 글자 단위 LIVE 터미널 입력, Ctrl-C 단축키, 그리고 더 조용한 알림 — 에이전트가 입력을 기다릴 때만 배너로. 본인 Tailscale로 cmux를 손안에서 제어하세요.
```
*(102 chars)*

### 키워드 (max 100)

```
cmux,터미널,터미널원격,tmux,tailscale,개발자,원격,claude,codex,wireguard,relay,코딩
```
*(68 chars — Korean keyword bytes count carefully, ASC limits chars not bytes)*

### 설명 (max 4000)

```
cmux Remote는 사용자의 모바일 기기를 본인 컴퓨터에서 돌아가는 cmux 터미널 멀티플렉서의 원격 헤드로 만들어 줍니다. Tailscale 네트워크 위에서 작동하므로 트래픽이 외부 relay를 거치지 않습니다.

이 앱이 무엇인가요

cmux (https://cmux.com)는 native splits, 워크스페이스, Claude Code / Codex / Cursor 같은 AI 에이전트와의 깊은 통합을 제공하는 데스크톱용 현대적 터미널 멀티플렉서입니다. cmux Remote는 선택한 cmux surface를 미러링하고, 키 입력을 보내고, 워크스페이스를 관리하고, 사진을 첨부하고, 알림을 받게 해 줍니다 — 전부 모바일 앱에서.

누구를 위한 앱인가요

- claude-code, codex, omx 같은 장시간 에이전트를 컴퓨터에서 돌리며, 소파에서 잠깐 들여다보거나 살짝 조작하고 싶은 개발자
- 이미 카페에서 본인 개발 머신에 SSH 접속하는 분들 — 더 깔끔한 경험을 원할 때
- Tailscale을 이미 쓰고 있고, 터미널 접근을 위한 사설 경로를 찾고 있는 분

어떻게 작동하나요

1. 컴퓨터에 오픈소스 cmux-relay 바이너리를 설치 (한 줄 설치 스크립트 제공).
2. 컴퓨터가 Tailscale에 연결되어 있는지 확인.
3. 이 앱을 열고 컴퓨터의 Tailscale 호스트명을 입력해 Connect 탭.
4. cmux 워크스페이스가 나타납니다. surface를 선택하면 끝.

릴레이는 컴퓨터에서 cmux의 로컬 Unix socket과 직접 통신합니다. 모바일 앱은 Tailscale의 WireGuard 암호화 터널을 통해 릴레이와 통신합니다. 본인 네트워크 밖으로 나가는 데이터는 없습니다.

주요 기능

- 한국어 / CJK 폭 처리와 styled relay 데이터 제공 시 ANSI 색상을 지원하는 성능 최적화 cmux 터미널 surface 라이브 미러
- 전용 키보드 액세서리 바 — Esc, Enter, Tab, 방향키, Ctrl-C, 기타 Ctrl 조합, /new, Space
- 전송 후 키보드 자동 닫힘과 키보드 표시 중 안정적인 터미널/입력창 레이아웃
- 모바일 클립보드 붙여넣기와 사진 첨부. 파일은 relay가 Downloads/cmux-remote 아래에 저장
- cmux 이벤트와 AI 에이전트 needs input 프롬프트를 로컬 알림 / native Inbox push로 표시
- 워크스페이스 생성, 이름 변경, 닫기와 다중 surface 칩바 전환
- relay가 제공하는 경우 연결된 컴퓨터 배터리 상태 표시
- 핀치 줌 폰트 사이즈, surface 전환 시 자동 하단 스크롤
- 데모 모드 — 릴레이 설정 전에도 가짜 데이터로 앱을 둘러볼 수 있음

개인정보 처리

분석 도구 없음. 광고 없음. 서드파티 SDK 없음. 릴레이가 발급하는 bearer 토큰은 iOS Keychain에만 저장됩니다. 전체 정책과 소스 코드:

https://github.com/NewTurn2017/cmux-remote

요구 사양

- cmux 0.64 이상이 설치된 개인 컴퓨터
- 컴퓨터와 모바일 기기 모두 같은 Tailscale tailnet에 로그인되어 있을 것
- iOS 17 이상

이 앱은 MIT 라이선스로 공개된 오픈소스입니다. Issues와 pull requests 환영.
```

### 저작권

```
© 2026 cmux Remote 기여자들. MIT 라이선스.
```

---

## Version 1.0.8 Release Notes

### What’s New — en-US

```
Cmux Remote 1.0.8 focuses on mobile terminal input polish, keyboard shortcuts, quieter notifications, and refreshed App Store copy.

- Adds LIVE input mode for immediate per-character terminal input, so English typing and quick key edits can be sent without pressing Enter or Submit.
- Protects Korean/Hangul IME input by keeping composed Korean text out of LIVE immediate-send mode, preventing jamo from being split while typing.
- Adds a dedicated Ctrl-C shortcut to the terminal keyboard bar for interrupting commands while coding.
- Removes the bottom gap under the terminal input panel so the composer sits flush with the bottom edge when the software keyboard is hidden.
- Adds five terminal rows of extra bottom scroll room, making it possible to pull terminal content above the input panel when the bottom rows would otherwise be covered.
- Adds native Inbox push delivery for cmux events and Claude/Codex-style “needs input” prompts, with APNs-backed routing and regression coverage.
- Adds a Settings control to reduce notification noise — only events that need your input raise an iOS banner, while everything still lands in the Inbox with unread badges.
- Fixes overlapping Korean/CJK text in the terminal mirror, so wide Hangul glyphs no longer bleed into neighboring columns on wide panes.
- Stops iOS smart punctuation from turning "--" into an em dash in the command composer, so CLI flags reach the terminal verbatim.
- Refreshes all five App Store screenshots to match the latest workspace, terminal, keyboard, Inbox, and settings screens.
```

### What's New

```
Cmux Remote 1.0.8 focuses on mobile terminal input polish, keyboard shortcuts, quieter notifications, and refreshed App Store copy.

- Adds LIVE input mode for immediate per-character terminal input, so English typing and quick key edits can be sent without pressing Enter or Submit.
- Protects Korean/Hangul IME input by keeping composed Korean text out of LIVE immediate-send mode, preventing jamo from being split while typing.
- Adds a dedicated Ctrl-C shortcut to the terminal keyboard bar for interrupting commands while coding.
- Removes the bottom gap under the terminal input panel so the composer sits flush with the bottom edge when the software keyboard is hidden.
- Adds five terminal rows of extra bottom scroll room, making it possible to pull terminal content above the input panel when the bottom rows would otherwise be covered.
- Adds native Inbox push delivery for cmux events and Claude/Codex-style “needs input” prompts, with APNs-backed routing and regression coverage.
- Adds a Settings control to reduce notification noise — only events that need your input raise an iOS banner, while everything still lands in the Inbox with unread badges.
- Fixes overlapping Korean/CJK text in the terminal mirror, so wide Hangul glyphs no longer bleed into neighboring columns on wide panes.
- Stops iOS smart punctuation from turning "--" into an em dash in the command composer, so CLI flags reach the terminal verbatim.
- Refreshes all five App Store screenshots to match the latest workspace, terminal, keyboard, Inbox, and settings screens.
```

### Release Notes

```
Cmux Remote 1.0.8 focuses on mobile terminal input polish, keyboard shortcuts, quieter notifications, and refreshed App Store copy.

- Adds LIVE input mode for immediate per-character terminal input, so English typing and quick key edits can be sent without pressing Enter or Submit.
- Protects Korean/Hangul IME input by keeping composed Korean text out of LIVE immediate-send mode, preventing jamo from being split while typing.
- Adds a dedicated Ctrl-C shortcut to the terminal keyboard bar for interrupting commands while coding.
- Removes the bottom gap under the terminal input panel so the composer sits flush with the bottom edge when the software keyboard is hidden.
- Adds five terminal rows of extra bottom scroll room, making it possible to pull terminal content above the input panel when the bottom rows would otherwise be covered.
- Adds native Inbox push delivery for cmux events and Claude/Codex-style “needs input” prompts, with APNs-backed routing and regression coverage.
- Adds a Settings control to reduce notification noise — only events that need your input raise an iOS banner, while everything still lands in the Inbox with unread badges.
- Fixes overlapping Korean/CJK text in the terminal mirror, so wide Hangul glyphs no longer bleed into neighboring columns on wide panes.
- Stops iOS smart punctuation from turning "--" into an em dash in the command composer, so CLI flags reach the terminal verbatim.
- Refreshes all five App Store screenshots to match the latest workspace, terminal, keyboard, Inbox, and settings screens.
```

### 새로운 기능 — ko

```
cmux Remote 1.0.8은 모바일 터미널 입력, 코딩용 단축키, 알림 소음 줄이기, App Store 표시 문구를 다듬은 업데이트입니다.

- 제출 버튼 없이 글자 단위로 바로 전송하는 LIVE 입력 모드를 추가했습니다.
- 한글/Hangul IME 입력은 LIVE 즉시 전송에서 제외해 입력 중 자모가 분리되지 않도록 했습니다.
- 코딩 중 실행 중인 명령을 끊을 수 있도록 터미널 키보드 바에 Ctrl-C 단축키를 추가했습니다.
- 키보드가 숨겨진 상태에서 터미널 입력 패널 아래에 생기던 하단 공백을 제거했습니다.
- 입력 패널에 가려질 수 있는 하단 터미널 내용을 위로 끌어올려 볼 수 있도록 터미널 하단에 5행 스크롤 여유를 추가했습니다.
- cmux 이벤트와 Claude/Codex 계열 “needs input” 프롬프트를 native Inbox push로 전달하도록 APNs 기반 라우팅과 회귀 테스트를 추가했습니다.
- 알림 소음을 줄이는 설정을 추가했습니다 — 사용자 입력이 필요한 이벤트만 iOS 배너로 알리고, 나머지는 Inbox 기록과 안 읽음 배지로만 유지합니다.
- 터미널 미러에서 한글/CJK 글자가 겹쳐 보이던 문제를 수정했습니다 — 넓은 pane에서도 겹치지 않습니다.
- 커맨드 입력창에서 iOS 스마트 구두점이 "--"를 em dash로 바꿔 CLI 옵션이 깨지던 문제를 수정했습니다.
- 워크스페이스, 터미널, 키보드, Inbox, 설정 화면을 반영해 App Store 스크린샷 5장을 모두 교체했습니다.
```

## App Privacy ("Data Used to Track You" / "Data Collected")

| Question | Answer |
|---|---|
| Does this app collect data? | **No** |
| Is data linked to user identity? | N/A |
| Is data used to track? | N/A |
| Third-party SDKs? | None |

The app stores `bearer` and `device_id` in the iOS Keychain, but these are issued by the **user's own** relay and never sent to any developer-controlled server. Per Apple's definition this is not "data collection".

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
Cmux Remote is a remote-control client for the cmux terminal multiplexer over the user's own Tailscale network. App Review cannot replicate this setup because it requires a computer running cmux + cmux-relay on a tailnet only the user controls.

To evaluate the full app:
1. Launch the app.
2. Tap the Settings tab (gear icon at the bottom).
3. Find the "demo mode" section near the top.
4. Tap [ TRY DEMO MODE ].
5. The app re-bootstraps with simulated workspaces, terminal output, and notifications. A yellow "DEMO" badge appears in the workspace header.

In demo mode you can:
- Browse six populated demo workspaces (agent-lab, study-bot, cmux-remote, next-app, infra-ops, inbox-zero)
- Open demo surfaces such as Claude Code, Codex, omx, shell, lazygit, vim, relay logs, and k9s
- Tap arrow keys / Esc / Tab / shortcut buttons — they no-op safely in demo mode
- Open the Inbox tab to see demo notifications, including an AI-agent needs-input example
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
| 3 | `03-keyboard-shortcuts.png` | Esc, Tab, arrows, and Ctrl-C built in | Esc · Tab · 방향키 · Ctrl-C 내장 |
| 4 | `04-inbox-notifications.png` | Native Inbox push for cmux events | cmux 이벤트 native Inbox push |
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
- [ ] Demo Mode verified to work in Release build for v1.0.8 build 10
- [ ] `ITSAppUsesNonExemptEncryption=false` in Info.plist (✅ done)
- [ ] PRIVACY.md committed and accessible at the URL above (✅ done)
- [ ] App Review Notes pasted from this document
- [ ] Both en-US and ko metadata filled in
- [ ] Screenshots uploaded for at least 6.9"
- [ ] In-App Purchases: none (v1.0)
- [x] Build archived with Release config + Distribution provisioning profile for v1.0.5 build 6
- [x] Build exported and validated for App Store Connect upload for v1.0.5 build 6
- [x] Build uploaded to App Store Connect for v1.0.5 build 6. Delivery UUID: `8e42ff35-6b51-4803-9f9c-bea2dde9063b`
- [x] Build 1.0.6 (8) previously uploaded to ASC (superseded — abandoned in favor of 1.0.8)
- [x] Build 1.0.7 (9) archived + exported with Push Notifications entitlement (aps-environment=production, App Store distribution profile)
- [x] Build 1.0.7 (9) uploaded to ASC on 2026-07-05 (train 1.0.7 now closed — superseded by 1.0.8)
- [ ] TestFlight internal test passes (recommended before public submit)
- [ ] Submit for Review
