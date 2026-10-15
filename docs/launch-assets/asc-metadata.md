# App Store Connect — Metadata Draft (v1.1.3 build 20)

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
See your terminal in true color, select and copy output, upload photos or files, and preview recent images — all through your private Tailscale connection.
```
*(155 chars)*

### Keywords (max 100, comma-separated, no spaces after commas)

```
cmux,terminal,ssh,tmux,tailscale,remote,developer,claude,codex,wireguard,relay
```
*(78 chars)*

### Description (max 4000)

```
Cmux Remote is a private remote-control client for the cmux terminal multiplexer running on your own computer. Connect over your Tailscale network — your traffic never touches a third-party relay.

WHAT IT IS

Cmux (https://cmux.com) is a modern terminal multiplexer with native splits, workspaces, and rich integrations for AI agents like Claude Code, Codex, omx, and Cursor. Cmux Remote mirrors the cmux surface you choose, lets you type into it, send keys, manage workspaces, upload photos and documents, preview images, and receive notifications — all from this mobile app.

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

- Performance-tuned live mirror of cmux terminal surfaces with Korean / CJK width support, opaque-black viewport fidelity, and ANSI truecolor
- Long-press drag selection with adjustable handles and one-tap copy
- Full keyboard accessory bar — Esc, Enter, Tab, arrows, Ctrl-C, other Ctrl combos, /new, and Space
- Keyboard-safe composer layout with automatic keyboard dismissal after submit and an inline scroll-to-bottom control
- Paste text from the mobile clipboard and upload photos or documents; files are saved by the relay under Downloads/cmux-remote
- Browse recent uploads and terminal-visible files, including image thumbnails and a full-screen zoom viewer
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
트루컬러 터미널, 드래그 선택·복사, 사진·파일 업로드와 최근 이미지 미리보기를 추가했습니다. 모든 연결은 기존처럼 사용자의 Tailscale 안에서만 이루어집니다.
```
*(92 chars)*

### 키워드 (max 100)

```
cmux,터미널,터미널원격,tmux,tailscale,개발자,원격,claude,codex,wireguard,relay,코딩
```
*(68 chars — Korean keyword bytes count carefully, ASC limits chars not bytes)*

### 설명 (max 4000)

```
cmux Remote는 사용자의 모바일 기기를 본인 컴퓨터에서 돌아가는 cmux 터미널 멀티플렉서의 원격 헤드로 만들어 줍니다. Tailscale 네트워크 위에서 작동하므로 트래픽이 외부 relay를 거치지 않습니다.

이 앱이 무엇인가요

cmux (https://cmux.com)는 native splits, 워크스페이스, Claude Code / Codex / Cursor 같은 AI 에이전트와의 깊은 통합을 제공하는 데스크톱용 현대적 터미널 멀티플렉서입니다. cmux Remote는 선택한 cmux surface를 미러링하고, 키 입력을 보내고, 워크스페이스를 관리하고, 사진과 문서를 업로드하고, 이미지를 미리 보고, 알림을 받게 해 줍니다 — 전부 모바일 앱에서.

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

- 한국어 / CJK 폭 처리, 불투명 검은 viewport, ANSI 트루컬러를 지원하는 성능 최적화 cmux 터미널 surface 라이브 미러
- 길게 눌러 드래그하는 선택 영역, 조절 핸들, 원탭 복사
- 전용 키보드 액세서리 바 — Esc, Enter, Tab, 방향키, Ctrl-C, 기타 Ctrl 조합, /new, Space
- 전송 후 키보드 자동 닫힘, 키보드 표시 중 안정적인 레이아웃, 인라인 맨 아래 이동 버튼
- 모바일 클립보드 붙여넣기와 사진·문서 업로드. 파일은 relay가 Downloads/cmux-remote 아래에 저장
- 최근 업로드 및 터미널에 표시된 파일 탐색, 이미지 썸네일과 전체 화면 확대 보기
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

## Version 1.1.3 Release Notes

### What’s New — en-US

```
- Switching to another terminal no longer shows the previous terminal's screen while the new one loads, and explains when a terminal can't be opened.
- Switching quickly between many workspaces stays reliable: a workspace no longer opens to the previous workspace's screen, and reloading the list no longer shows "connecting".
- Reconnects automatically while your Mac's relay or Tailscale is still starting, with clearer connection and pairing messages.
- Works with the hardened relay that binds each pairing to its Tailscale device. Thanks to Francesco Frapporti for responsibly reporting the issue.
```

### 새로운 기능 — ko

```
- 다른 터미널로 전환할 때 새 화면을 불러오는 동안 이전 터미널 화면이 남지 않으며, 터미널을 열 수 없으면 이유를 알려 줍니다.
- 워크스페이스가 많아도 빠르게 전환할 수 있습니다. 워크스페이스를 열었는데 이전 워크스페이스 화면이 남아 있거나, 목록을 다시 불러올 때 "connecting"이 표시되는 문제를 고쳤습니다.
- Mac의 relay나 Tailscale이 아직 시작 중이면 자동으로 다시 연결하고, 연결·페어링 상태 메시지를 더 명확하게 표시합니다.
- 페어링을 각 Tailscale 기기에 묶도록 강화된 relay와 함께 동작합니다. 이 문제를 책임 있게 제보해 주신 Francesco Frapporti 님께 감사드립니다.
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

Not used. No advertising identifiers, advertising SDKs, or tracking.

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

Source: `docs/launch-assets/screenshots/1.1.1/`

| # | File | Caption (EN) | 자막 (KR) |
|---|---|---|---|
| 1 | `iphone-6.9/{locale}/01-remote-command-center.png` | Your Mac terminal. In your hand. | Mac의 cmux를 손안에서 |
| 2 | `iphone-6.9/{locale}/02-truecolor-selection-copy.png` | True color. Precise selection. | 색은 그대로, 선택은 정밀하게 |
| 3 | `iphone-6.9/{locale}/03-terminal-files-preview.png` | Terminal files. On your phone. | 터미널의 파일을 바로 열어보세요 |
| 4 | `iphone-6.9/{locale}/04-compact-command-deck.png` | Faster commands. More terminal room. | 명령은 빠르게, 터미널은 더 넓게 |
| 5 | `iphone-6.9/{locale}/05-private-tailscale.png` | Private by design. Yours end to end. | 내 네트워크 안에서 안전하게 |

Sizes needed:
- ✅ 6.9" (1320×2868) — 5 English + 5 Korean
- ✅ iPad 13" landscape (2752×2064) — 3 English + 3 Korean
- ⚠️ 6.5" (1284×2778) — Apple auto-scales from 6.9", but recommended to provide native captures
- ⚠️ 6.7" (1290×2796) — same

App previews (video): not required for v1.0.

## Localization checklist

| Locale | App Name | Subtitle | Description | Keywords | Screenshots |
|---|---|---|---|---|---|
| en-US (primary) | ✅ | ✅ | ✅ | ✅ | ✅ iPhone + iPad |
| ko (secondary) | ✅ | ✅ | ✅ | ✅ | ✅ iPhone + iPad |

## Submission checklist

- [ ] Apple Developer Program active ($99/yr)
- [ ] App registered in App Store Connect with bundle id `com.genie.CmuxRemote`
- [ ] Demo Mode verified to work in Release build for v1.1.1 build 17
- [ ] `ITSAppUsesNonExemptEncryption=false` in Info.plist (✅ done)
- [ ] PRIVACY.md committed and accessible at the URL above (✅ done)
- [ ] App Review Notes pasted from this document
- [ ] Both en-US and ko metadata filled in
- [ ] Localized iPhone 6.9" and iPad 13" screenshots uploaded
- [ ] In-App Purchases: none (v1.0)
- [x] Build archived with Release config + Distribution provisioning profile for v1.0.5 build 6
- [x] Build exported and validated for App Store Connect upload for v1.0.5 build 6
- [x] Build uploaded to App Store Connect for v1.0.5 build 6. Delivery UUID: `8e42ff35-6b51-4803-9f9c-bea2dde9063b`
- [x] Build 1.0.6 (8) previously uploaded to ASC (superseded — abandoned in favor of 1.0.8)
- [x] Build 1.0.7 (9) archived + exported with Push Notifications entitlement (aps-environment=production, App Store distribution profile)
- [x] Build 1.0.7 (9) uploaded to ASC on 2026-07-05 (train 1.0.7 now closed — superseded by 1.0.8)
- [x] Build 1.0.9 (12) uploaded to ASC and marked VALID on 2026-08-02
- [ ] Build 1.1.1 (17) archived, uploaded, processed, and attached
- [ ] TestFlight internal test passes (recommended before public submit)
- [ ] Submit for Review
