🇰🇷 한국어 · [🇺🇸 English](README.en.md)

# cmux Remote

> Tailscale 네트워크 너머에서 [cmux](https://github.com/manaflow-ai/cmux)
> 터미널을 iPhone으로 조작하는 비공식 원격 클라이언트.

cmux Remote는 Mac에서 돌아가는 cmux의 작업공간과 터미널을 iPhone에서
읽고 조작할 수 있게 해주는 SwiftUI 앱 + Swift 데몬 묶음입니다. 모든
트래픽은 사용자의 Tailscale tailnet 안에서만 흐르며, 공용 인터넷으로
노출되는 포트는 없습니다.

이 프로젝트는 **Manaflow가 만들거나 공식 지원하는 결과물이 아닙니다.**
cmux와 문서화된 JSON-RPC 프로토콜로만 통신하는 독립 네트워크 클라이언트.

---

## 상태

**얼리 프리뷰 (v1.0).** 다음이 됩니다:

- cmux 작업공간 / surface 목록 보기, 새로 만들기, 닫기
- 임의의 터미널 surface를 실시간 미러링 (15Hz diff 폴링)
- 키 입력 / 키 조합 / 텍스트 / 커맨드 라인 전송
- cmux 알림을 iOS 로컬 알림으로 표시 (앱이 살아있는 동안)
- 마우스 모드 TUI 탭 입력 (Textual / Bubble Tea / fzf / omx 등)
- pane 포커스 자동 고정 + 이전 pane 토글

macOS 14 + iOS 17 실기기 + 시뮬레이터에서 같은 Wi-Fi와 Tailnet
환경에서 스모크 테스트했습니다 (Tailscale 1.84+).

> **알림 한계** — 현재 알림은 *로컬* 알림입니다. 앱이 foreground이거나
> 백그라운드에서 WebSocket이 살아있는 동안만 iOS 배너가 뜹니다. 진짜
> APNs 푸시(앱이 종료/장시간 백그라운드일 때도 도달)는 v1.1 로드맵.

## 스크린샷

<p align="center">
  <img src="docs/launch-assets/source/cmux-remote-brandmark-transparent.png" alt="cmux Remote 브랜드마크" width="320">
</p>

<table>
  <tr>
    <td align="center" width="20%"><img src="docs/launch-assets/screenshots/app-store-6.9/01-workspaces-remote-control.png" alt="작업공간 원격 제어" width="180"><br><sub>작업공간 / surface 칩바</sub></td>
    <td align="center" width="20%"><img src="docs/launch-assets/screenshots/app-store-6.9/02-terminal-live-control.png" alt="터미널 실시간 제어" width="180"><br><sub>터미널 실시간 미러링</sub></td>
    <td align="center" width="20%"><img src="docs/launch-assets/screenshots/app-store-6.9/03-keyboard-shortcuts.png" alt="키 액세서리 바" width="180"><br><sub>키 액세서리 바</sub></td>
    <td align="center" width="20%"><img src="docs/launch-assets/screenshots/app-store-6.9/04-inbox-notifications.png" alt="알림 Inbox" width="180"><br><sub>알림 Inbox</sub></td>
    <td align="center" width="20%"><img src="docs/launch-assets/screenshots/app-store-6.9/05-settings-connection-guide.png" alt="설정 / 연결" width="180"><br><sub>설정 · 페어링 가이드</sub></td>
  </tr>
</table>

---

## 왜?

cmux는 AI 코딩 에이전트를 굴리기에 훌륭한 Mac 네이티브 터미널이지만,
책상을 떠나는 순간 모든 진행이 화면 너머로 사라집니다. cmux Remote는
같은 작업공간에 얇은 유리창을 하나 더 붙여서, 소파에서, 지하철에서,
카페에서도 Mac이 하고 있는 일을 확인하고 키 입력으로 끼어들 수 있게
합니다. 일은 여전히 Mac이 다 하고, iPhone은 그저 원격 조종기.

---

## 아키텍처

```
iPhone (iOS 17+)         Tailscale            Mac
┌─────────────────────┐                       ┌────────────────────────────────┐
│ cmux Remote (앱)    │── HTTP + WS ─────────▶│ cmux-relay (Swift, launchd)    │
│  · 작업공간 목록    │   (Tailscale가 암호화)│  · HTTP/1.1 라우트             │
│  · 터미널 미러      │                       │  · /v1/stream WebSocket        │
│  · 액세서리 키바    │◀── events.stream ─────│  · DiffEngine (15Hz 폴링)      │
│  · 로컬 알림        │                       │  · Tailscale whois 인증        │
└─────────────────────┘                       │  · 디바이스 토큰 + Rate Limit  │
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

설치는 두 파트:

1. **`cmux-relay`** — cmux와 같은 Mac에서 도는 Swift 데몬. cmux의 로컬
   Unix 소켓에 JSON-RPC로 붙고, tailnet 인터페이스에 HTTP+WebSocket을
   띄웁니다. TLS는 Tailscale의 WireGuard 전송이 담당.
2. **cmux Remote (iOS)** — SwiftUI 앱. 사용자 본인의 relay에만 붙고,
   외부 네트워크로 나가는 호출은 없습니다.

cmux 소스 코드는 이 저장소에 포함되지 않습니다. 문서화된 JSON-RPC
스키마로만 cmux와 통신합니다.

---

## 기능

### 작업공간 / surface

- 작업공간 / 터미널 surface 목록
- 칩바에서 surface 생성 / 닫기 (확정 다이얼로그 포함)
- 작업공간 전환 / surface 전환 시 자동 재구독 + 하단 자동 스크롤
- 첫 RPC 게이트 (`CMUXClient.awaitReady`) — inbound bridge 설치 race 방지

### 터미널 미러

- 15Hz diff 폴링 + 풀텍스트 fallback + checksum reconcile
- 핀치 줌 (8–32pt), 부드러운 앵커 고정
- Tokyo Night Storm ANSI 팔레트 + CRT 스캔라인 셰이더
- 동아시아 와이드 글리프 폭 계산
- iOS 컬러 이모지 자동 승격 차단 (●, ⏺, ✔, ▶ 등에 VS-15 적용)

### 입력

- 액세서리 바: `esc` `↵` `⇧↵` `/` `$` `tab` `← ↑ ↓ →` `ms` `↺p`
- 커맨드 컴포저 — 텍스트 입력 + 엔터 묶음 전송, 모디파이어 토글
- `surface.send_key`는 `NSEvent` synth — 화살표/Ctrl 조합 등 멀티바이트
  시퀀스가 atomic하게 전달. Ink 기반 TUI (Claude Code 등)의 ESC 파서
  타임아웃 문제 해결.
- **포커스 게이트** — 구독 / 재구독 / 매 sendKey 직전 `surface.focus`
  자동 호출. 책상에서 cmux 포커스를 옮긴 뒤에도 iPhone 키가 의도한
  surface로 도착.
- **pane 토글 (`↺p`)** — omx 등이 raw-mode 프롬프트를 서브 pane으로
  띄울 때 그쪽으로 포커스 점프. `pane.last` 실패 시 `pane.list` 폴백.
- **마우스 패스스루 (`ms`)** — 토글하면 터미널 탭이 xterm SGR
  press/release로 전송. Textual / Bubble Tea / fzf / omx 메뉴가 반응.

### 알림

- cmux events.stream의 notification을 iOS 로컬 알림으로 표시
  (`UNUserNotificationCenter`, threadIdentifier로 작업공간별 그룹핑)
- 권한은 lazy 요청, 부팅 시 한 번 prewarm
- 중복 ID 가드 — 재연결로 같은 알림이 두 번 와도 한 번만 배너
- Inbox 화면 — 최근 200건 보관, 가장 최근 먼저
- 딥링크 `cmux://surface/<id>` 처리 (M6 APNs 합류 예정)
- Settings의 `SEND TEST NOTIFICATION` 버튼 — 로컬 inject 즉시 확인 +
  relay→cmux→events.stream 라운드트립 별도 상태 라인

### Mac relay

- HTTP/1.1 + WebSocket upgrade (`SwiftNIO`)
- JSON-RPC 2.0 dispatch
- DiffEngine — actor 기반, per-device FPS 예산, row 단위 diff
- 인증: Tailscale UDS `whois` (foreground) / GUI fallback
- 디바이스 토큰: hashed bearer, 메뉴바에서 개별 revoke
- per-device rate limiter + boot_id 기반 reset 브로드캐스트
- launchd 유저 에이전트로 자동 시작, PATH 주입으로 `tailscale` CLI 발견
- events.stream 전용 cmux UDS 채널 분리 (구독 채널은 push-only lock)

### 보안

- Relay는 0.0.0.0에 바인딩하되 비-Tailscale 소스 주소를 *애플리케이션
  레이어*에서 거부 (`EndpointPolicy`)
- 디바이스별 토큰 + 메뉴바 revoke
- 알림 페이로드에는 터미널 내용 미포함 (작업공간/surface id + 짧은
  제목만)
- 텔레메트리 없음, 분석 없음, 서드파티 네트워크 호출 없음

---

## 요구사항

### Mac (relay)

- macOS 13 Ventura 이상
- [cmux](https://github.com/manaflow-ai/cmux) 설치 + 소켓 노출
  (기본 `~/Library/Application Support/cmux/cmux.sock`)
- Swift 5.10 툴체인 (Xcode 15.3+) — 소스에서 빌드용
- Tailscale 로그인 상태
- 비어있는 TCP 포트 (기본 `4399`)

### iPhone

- iOS 17 이상
- Mac과 같은 Tailnet (Tailscale 앱 로그인)
- 사이드로딩용 Apple Developer 계정 (개인 무료 7일 인증서로도 가능)

### 네트워크

- Tailscale 1.84+ 양쪽
- Funnel 불필요, 외부 hostname 불필요

---

## 빠른 시작

### 1. Mac에 relay 빌드 + 설치

```bash
git clone https://github.com/NewTurn2017/cmux-remote.git
cd cmux-remote
swift build -c release --product cmux-relay

# launchd 유저 에이전트로 설치 (로그인 시 자동 시작)
./scripts/install-launchd.sh
```

설치 스크립트는 바이너리를 `~/.cmuxremote/bin/`로 복사하고,
`~/Library/LaunchAgents/com.genie.cmuxremote.plist`를 렌더링한 뒤
서비스를 부트스트랩합니다. 로그는 `~/.cmuxremote/log/`로 떨어집니다.

헬스 체크:

```bash
curl -s http://$(tailscale ip -4):4399/v1/health
# {"ok":true,"version":"0.1.0"}
```

소켓 점검:

```bash
./scripts/cmux-probe.sh
# {"id":"probe-1","result":{...}}
```

### 2. iPhone 페어링

iPhone에서 cmux Remote 열기:

1. **Add Mac** 탭
2. Tailscale IP 또는 MagicDNS 이름 입력 (포트 `4399`)
3. Mac 메뉴바에서 페어링 승인

페어링 시 디바이스별 토큰이 발급됩니다. 메뉴바에서 언제든 개별 revoke.

### 3. 사용

- **Workspaces** — 작업공간 목록. 탭하면 surface 칩바가 펼쳐짐.
- **Terminal** — 탭한 surface가 미러링. 하단 액세서리 바로 키 입력.
  키보드 줄, esc / 화살표 / tab / 마우스 모드 / pane 토글 다 거기.
- **Notifications** — cmux 알림 Inbox. 앱이 살아있을 때 도착한
  알림이 시간순으로 쌓입니다. iOS 배너도 같이 떠요 (포그라운드/짧은
  백그라운드).
- **Settings** — 호스트/포트, 재연결, 테스트 알림 발사.

---

## 설정

Relay는 `~/.cmuxremote/relay.json`을 읽습니다 (`install-launchd.sh`가
없으면 생성):

```json
{
  "listen":      "0.0.0.0:4399",
  "cmux_socket": "/Users/<you>/Library/Application Support/cmux/cmux.sock",
  "diff_hz":     15
}
```

`listen`은 0.0.0.0이지만 비-Tailscale 소스 주소는 애플리케이션
레이어에서 차단됩니다. 개발 중 localhost를 허용하려면
`CMUX_DEV_ALLOW_LOCALHOST=1` 환경 변수로 install 스크립트를 돌리세요.

> **APNs 키 필드 (`apns_team_id`, `apns_key_id`, `apns_key_path`)는
> v1.1에서 도입 예정.** 현재는 cmux 알림이 로컬 알림으로만 표시되며,
> 앱이 종료된 상태에서는 도달하지 않습니다.

---

## 로드맵

- [x] v1.0 — 작업공간 목록, surface 생성/닫기, 터미널 미러, 키 입력,
      마우스 모드, pane 토글, 로컬 알림, Tokyo Night Storm UI
- [ ] **v1.1 — APNs 푸시** (백그라운드/종료 상태 알림), 푸시 페이로드
      → 딥링크 surface 자동 오픈
- [ ] v1.2 — iPad 레이아웃, 외장 키보드 폴리시
- [ ] v1.3 — cmux "open in pane" 인텐트용 파일 프리뷰
- [ ] v2.0 — 고빈도 TUI(vim, htop, k9s) 대상 바이트스트림 RPC
- [ ] 혹시 — Android 클라이언트 (PR 환영, `docs/specs/` 참고)

명시적 비목표: 공용 인터넷 노출(Tailscale Funnel), 멀티유저 공유,
라이브 세션 외부의 서버측 영속 저장.

---

## 프로젝트 구조

```
cmux-remote/
├─ README.md / README.en.md
├─ LICENSE
├─ docs/
│  ├─ screenshots/          # README용 스크린샷
│  └─ specs/                # 설계 문서, 결정 RFC
├─ Package.swift            # SharedKit / CMUXClient / RelayCore / cmux-relay
├─ Sources/
│  ├─ SharedKit/            # Codable 모델, JSON-RPC 봉투, 키 테이블, 스크린 해셔
│  ├─ CMUXClient/           # cmux UDS JSON-RPC 클라이언트 (Mac 전용)
│  ├─ RelayCore/            # Auth, Session, DiffEngine, RowState, DeviceStore
│  └─ RelayServer/          # @main, NIO HTTP+WS, launchd 엔트리
├─ Tests/                   # 유닛 + 통합 테스트
├─ ios/
│  ├─ CmuxRemote.xcodeproj
│  └─ CmuxRemote/
│     ├─ CmuxRemoteApp.swift / ContentView.swift
│     ├─ Network/           # RPCClient, WSClient, AuthClient, EndpointPolicy
│     ├─ Notifications/     # LocalNotificationPresenter, NotificationCenterView
│     ├─ Stores/            # WorkspaceStore, SurfaceStore, NotificationStore
│     ├─ Terminal/          # CellGrid, ANSIParser, TerminalView, 셀폭 계산
│     ├─ Workspace/         # WorkspaceListView, WorkspaceDrawer, WorkspaceView
│     ├─ Settings/          # SettingsView
│     ├─ Keyboard/          # CommandComposer
│     ├─ UI/                # Tokyo Night 테마, 스플래시, Metal 셰이더
│     ├─ Security/          # HardeningCheck
│     └─ Storage/           # Keychain
└─ scripts/
   ├─ install-launchd.sh    # cmux-relay launchd 설치
   ├─ uninstall-launchd.sh
   ├─ relay.plist.tmpl
   ├─ cmux-probe.sh         # cmux 소켓 핑
   ├─ smoke-relay.sh        # tailnet end-to-end 스모크
   └─ evaluate-terminal-keyboard.sh
```

> 내부 식별자는 camelCase `CmuxRemote` (Xcode 타깃, Swift 모듈,
> 번들 ID `com.genie.CmuxRemote`). 홈스크린 표시 이름은 공백을
> 둔 **cmux Remote**. 양쪽 다 정상.

---

## 개발

```bash
# Swift 테스트 전체 (relay + shared kits)
swift test

# iOS 앱 Xcode 프로젝트 생성
cd ios && xcodegen generate

# 시뮬레이터에서 iOS 테스트 (Fake RPC 디스패치)
xcodebuild test -project CmuxRemote.xcodeproj \
  -scheme CmuxRemote -destination 'platform=iOS Simulator,name=iPhone 15'

# 실제 cmux + Tailscale 풀스택 스모크 (느림, 에페메럴 노드 사용)
SMOKE_EPHEMERAL=1 ./scripts/smoke-relay.sh
```

스모크 스크립트는 임시 Tailscale 노드 + 격리된 config 디렉토리를
띄우고, 가짜 디바이스를 등록한 뒤 문서화된 모든 relay 엔드포인트
(`/v1/health`, `/v1/devices/me/register`, `/v1/state`,
`/v1/devices/me/apns`, WebSocket hello, `workspace.list`,
`surface.list`, `surface.subscribe`, `screen.diff`,
`screen.checksum`)를 차례로 두드립니다. relay 와이어 포맷을
건드릴 때 유용.

iOS 앱은 `FAKE_RPC=1` (DEBUG 빌드 기본값) 또는 시뮬레이터에서
`FakeRPCDispatch`를 사용해 relay 없이도 빌드 + UI 테스트가
돌아갑니다.

---

## 기여

이슈와 PR 환영합니다. 몇 가지 규칙:

- PR 하나에 기능 하나. diff는 작게.
- 테스트 추가/갱신. relay는 단위 커버리지가 있고, iOS는 fake-relay
  디스패치로 UI 테스트가 돕니다.
- cmux 소스를 이 저장소에 붙여넣지 마세요. 라이선스 분리 유지가
  중요 (아래 참고).
- 버그 리포트에는 relay 로그 + cmux 버전 (`cmux --version`)을 같이.

더 큰 아이디어(새 transport, 새 auth 모델, 바이트스트림 RPC 등)는
discussion을 열거나 `docs/specs/`에 디자인 문서를 먼저 올려주세요.

---

## 보안

- Relay는 tailnet 인터페이스만 받아들입니다 — 비-Tailscale 소스 주소는
  애플리케이션 레이어에서 거부 (개발용 localhost 허용은
  `CMUX_DEV_ALLOW_LOCALHOST=1`로만).
- iPhone마다 페어링 시 발급된 토큰을 가집니다. 메뉴바에서 개별 revoke.
- 알림 페이로드에는 터미널 내용이 포함되지 않습니다 — workspace/surface
  id + 짧은 title만.
- 텔레메트리 / 분석 / 서드파티 네트워크 호출 없음.

보안 이슈는 이슈 트래커에 공개로 올리지 말고 `SECURITY.md`의 메인테이너
이메일로 알려주세요.

---

## 라이선스

cmux Remote는 **MIT 라이선스** — [`LICENSE`](LICENSE) 참조.

### cmux와의 관계

[cmux](https://github.com/manaflow-ai/cmux)는 © Manaflow, Inc.,
GPL-3.0-or-later 또는 상용 라이선스로 듀얼 라이선스됩니다. cmux Remote는
**독립 네트워크 클라이언트**입니다. cmux 소스 코드를 포함하거나, 링크하거나,
수정하지 않습니다. 통신은 전적으로 문서화된 JSON-RPC 프로토콜을 통해서만
이루어집니다. Free Software Foundation은 GPL 프로그램과 문서화된 네트워크
프로토콜을 통해서만 상호작용하는 프로그램은 그 프로그램의 파생 저작물이
아니라는 일반적 입장을 가지고 있으며, cmux Remote는 이에 근거해 배포됩니다.

### 상표 고지

"cmux"는 Manaflow, Inc.가 자사 터미널 제품을 식별하기 위해 사용하는
이름입니다. cmux Remote는 이 클라이언트가 상호운용되도록 설계된
소프트웨어를 식별하기 위한 *기술적 묘사 용도*로만 이 이름을 사용합니다.
cmux Remote는 Manaflow, Inc.와 제휴, 후원, 추천 관계가 아닙니다. Manaflow
측에서 이름 변경을 요청하시면 이슈를 열어주세요 — 군말 없이 이름을
바꾸겠습니다.

---

## 감사의 말

- [cmux](https://github.com/manaflow-ai/cmux) 팀 — 이 앱이 확장하는
  터미널을 만들어 주셔서.
- [Tailscale](https://tailscale.com) — 지루할 만큼 완벽한 전송.
- [SwiftNIO](https://github.com/apple/swift-nio) — relay의 HTTP/WS 스택.
