🇰🇷 한국어 · [🇺🇸 English](connection-guide.en.md)

# cmux Remote 연결 가이드

> iPhone 앱이 Mac에 연결되지 않을 때, **누구나 따라 할 수 있는** 설치 +
> 문제 해결 안내입니다. 명령은 전부 **Mac에서** 실행합니다. 위에서부터
> 한 줄씩 그대로 복사해 붙여넣으면 됩니다.

cmux Remote는 두 부분으로 동작합니다.

- **Mac**: cmux 옆에서 `cmux-relay`(작은 백그라운드 서비스)가 돌면서
  iPhone의 요청을 받습니다.
- **iPhone**: cmux Remote 앱이 Tailscale 너머로 그 relay에만 붙습니다.

iPhone이 연결되려면 **① cmux 실행 + ② relay 실행 + ③ 같은 Tailnet** 세
가지가 동시에 만족돼야 합니다. 연결이 안 되면 거의 항상 이 셋 중 하나가
빠진 것입니다.

---

## 0. 준비물 (한 번만)

```bash
cmux --version       # cmux가 설치돼 있고 실행 중이어야 함
tailscale status     # Tailscale에 로그인 + 온라인이어야 함
swift --version      # Swift 5.10+ (Xcode 15.3 이상)
```

- `cmux`가 없다면 → [cmux](https://github.com/manaflow-ai/cmux)를 먼저 설치하고 실행하세요.
- `tailscale`이 없다면 → [Tailscale](https://tailscale.com/download)을 Mac과 iPhone **양쪽**에 설치하고 같은 계정으로 로그인하세요.
- `swift`가 없다면 → App Store에서 Xcode를 설치하세요(또는 `xcode-select --install`).

---

## 1. 설치 (Mac)

```bash
git clone https://github.com/NewTurn2017/cmux-remote.git
cd cmux-remote
./scripts/install-launchd.sh
```

이 한 줄이 알아서:

1. relay를 릴리스 모드로 빌드하고 (`~/.cmuxremote/bin/`)
2. 설정 파일이 없으면 기본값으로 만들고 (`~/.cmuxremote/relay.json`)
3. 로그인 시 자동 시작되는 백그라운드 서비스로 등록합니다.

로그는 `~/.cmuxremote/log/`에 쌓입니다.

> 빌드는 처음 한 번은 몇 분 걸릴 수 있습니다. `swift` 또는 `launchctl`이
> 없다는 에러가 나면 위 **준비물**을 다시 확인하세요.

---

## 2. relay가 떴는지 확인 (Mac)

```bash
curl -s http://$(tailscale ip -4):4399/v1/health
```

`{"ok":true,"version":"0.1.0"}` 가 나오면 **relay 정상**입니다.

cmux 소켓에도 붙었는지 한 번 더 확인:

```bash
./scripts/cmux-probe.sh
# {"id":"probe-1","result":{...}}  ← 이렇게 result가 나오면 OK
```

둘 다 정상이면 3단계(페어링)로 넘어가세요. 응답이 없으면 **4. 연결이
안 될 때**로.

---

## 3. iPhone 페어링

Mac의 주소를 먼저 확인합니다.

```bash
tailscale ip -4      # 예: 100.101.102.103  ← 이 IP를 앱에 입력
tailscale status     # MagicDNS 이름(예: my-mac)을 쓰고 싶을 때
```

iPhone에서 cmux Remote 앱을 열고:

1. **Add Mac** 탭
2. 위 IP(또는 MagicDNS 이름) 입력, 포트는 **`4399`**
3. Mac 메뉴바에 뜨는 페어링 요청을 **승인**

연결되면 작업공간 목록이 보입니다.

### 터미널 렌더링과 선택/복사

연결 후 터미널은 다음 규칙으로 동작합니다.

- 라이브 `cmux.render-grid.v1` 리플레이는 RGB 전경색과 배경색 값을 터미널 셀에서 그대로 보존합니다.
- 연결 시 capability를 협상합니다. 완전한 replay contract를 제공하지 않는 구버전 cmux는 자동으로 평문 `surface.read_text` 경로를 사용합니다.
- 터미널 셀을 길게 누른 뒤 드래그하면 텍스트를 선택할 수 있습니다.
- 선택이 끝나면 양 끝점 핸들(endpoint handle)을 드래그해 선택 범위를 조정할 수 있습니다.
- **Copy**는 평문만 클립보드에 쓰며 CJK 문자, 공백, 빈 줄을 보존합니다.
- 비어 있지 않은 명령은 앞뒤 공백을 제거하고 줄바꿈을 공백으로 바꾸며 내부 반복 공백을 보존합니다. 정규화된 텍스트를 한 번의 `surface.send_text` payload로 보낸 뒤 한 번의 `Enter`를 전송합니다. 공백만 입력하면 `Enter`만 전송합니다.
- 터미널 viewport의 바탕은 불투명한 검정입니다. 셀에 명시된 ANSI 배경색은 그 바탕 위에 계속 표시됩니다.

---

## 4. 연결이 안 될 때 (체크리스트)

위에서부터 한 줄씩 확인하세요. **대부분 ①~②에서 해결됩니다.**

```bash
SERVICE="gui/$(id -u)/com.genie.cmuxremote"
```

### ① cmux가 켜져 있나?

cmux 앱이 꺼져 있으면 relay가 화면을 읽지 못합니다.

```bash
cmux --version
# cmux 앱을 켠 다음:
launchctl kickstart -k "$SERVICE"
```

### ② relay가 살아 있나?

```bash
curl -s http://$(tailscale ip -4):4399/v1/health
```

- 응답이 없으면 재시작: `launchctl kickstart -k "$SERVICE"`
- 그래도 안 되면 재설치: `./scripts/install-launchd.sh`
- 상태 확인: `launchctl print "$SERVICE" | grep -E "state|pid|last exit"`

### ③ 로그가 정상인가?

```bash
tail -n 40 ~/.cmuxremote/log/stderr.log
```

정상이면 아래 3줄이 보입니다:

```
starting cmux-relay on 0.0.0.0:4399
listening …
cmux event stream attached
```

로그에 따라:

| 로그 메시지 | 뜻 | 조치 |
|---|---|---|
| `cmux event stream unavailable: socketMissing` | cmux가 꺼져 있음 | cmux 앱을 켜고 `launchctl kickstart -k "$SERVICE"` |
| `Connection refused` 반복 | cmux 재시작으로 소켓 이름이 바뀜 | `launchctl kickstart -k "$SERVICE"`, 그래도면 `./scripts/install-launchd.sh` 재실행 |
| `cmux event stream attached` 직후 `detached` 반복 | cmux 소켓 접근 거부(cmux 0.64+) | 아래 **③a** 확인 |
| `attached` 후 약 30초 뒤 `detached` 반복 | password 모드는 켜졌는데 소켓 비밀번호가 비어 있음 | 아래 **③a** 확인 |
| 3줄 정상인데 앱만 못 붙음 | 네트워크/주소 문제 | ④⑤ 확인 |

### ③a 소켓 접근 거부(cmux 0.64+)

cmux 0.64부터 소켓 접근 제어 모드의 기본값은 `cmuxOnly`입니다. 이 모드는
**프로세스 계보**로 인가하므로 cmux 안에서 실행된 프로세스만 연결할 수
있고, 외부 launchd agent인 relay는 이렇게 거부당합니다:

```text
ERROR: Access denied — only processes started inside cmux can connect
```

해결하려면 cmux를 password 모드로 바꾸고 소켓 비밀번호를 설정하세요.

**1. 모드 설정.** cmux가 실행될 때 `~/.config/cmux/cmux.json`을 만들어
두므로, 덮어쓰지 말고 기존 파일을 편집하세요(먼저 백업 권장):

```jsonc
{
  "automation": {
    "socketControlMode": "password"
  }
}
```

cmux Settings → Automation에서 모드를 바꿔도 됩니다.

**2. cmux 앱 재시작.** `cmux reload-config`로는 부족합니다 — cmux
0.64.19 기준 소켓 리스너는 `socketControlMode`를 시작 시점에만 읽습니다.

> cmux를 재시작하면 그 안에서 실행 중인 모든 것이 함께 종료됩니다.
> cmux 워크스페이스에서 돌던 에이전트 세션도 포함되니 미리 정리하세요.

**3. cmux Settings에서 비밀번호 설정.** cmux에서 ⌘, → **Automation**
에서 소켓 비밀번호를 설정하세요. 파일로는 설정할 수 없습니다 — cmux
0.64.19 기준 비밀번호는 Keychain에 저장되며, 재시작 시 cmux가
`cmux.json`의 `automation.socketPassword` 키와 아래 비밀번호 파일을
모두 제거합니다.

**4. relay 재시작**으로 비밀번호를 읽히세요:

```bash
launchctl kickstart -k "$SERVICE"
```

relay는 프로세스 시작 시 아래 순서에서 처음 발견한 비어 있지 않은
비밀번호를 한 번 읽습니다:

1. `CMUX_SOCKET_PASSWORD`
2. `XDG_STATE_HOME`이 설정된 경우
   `$XDG_STATE_HOME/cmux/socket-control-password`
3. `~/.local/state/cmux/socket-control-password`
4. `~/Library/Application Support/cmux/socket-control-password`

비밀번호를 설정하면 cmux가 state 디렉터리의 파일을 기록합니다.
비밀번호를 바꾼 뒤에는 항상 relay를 재시작하세요.

**모드만 켜지고 비밀번호가 비어 있으면** cmux가 연결을 받아들였다가 약
30초의 유예 후 끊습니다. 그래서 로그에 `attached`와 `detached`가 30초
주기로 반복됩니다. 이 상태에서는 cmux CLI 자체도 `auth_required`로
실패합니다. 위 탐색 순서에서 현재 환경에 해당하는 값이나 비밀번호
파일이 존재하고 비어 있지 않은지 확인하세요.

### ④ Tailscale이 양쪽 다 온라인인가?

```bash
tailscale status
```

- Mac과 iPhone이 **같은 Tailnet(같은 계정)** 에 로그인돼 있어야 합니다.
- iPhone의 Tailscale 앱에서 연결이 켜져 있는지 확인하세요.

### ⑤ 앱에 입력한 주소가 맞나?

```bash
tailscale ip -4
```

- 앱에 이 **IP**와 포트 **`4399`** 를 정확히 입력했는지 확인하세요.
- MagicDNS 이름을 썼다면 `tailscale status`의 이름과 철자가 같아야 합니다.

### 그래도 안 되면

이전에 페어링했던 기기 토큰이 막혀 있을 수 있습니다.

```bash
.build/release/cmux-relay devices list     # 등록된 기기 확인
# 필요하면 해당 기기 제거 후 앱에서 다시 페어링:
# .build/release/cmux-relay devices revoke <device-id>
```

---

## 자주 묻는 질문

**Q. cmux를 재시작했더니 다시 연결이 끊겨요.**
cmux는 재시작할 때 내부 소켓 이름이 바뀔 수 있습니다. relay를 다시
붙이는 가장 빠른 방법:

```bash
launchctl kickstart -k "gui/$(id -u)/com.genie.cmuxremote"
```

**Q. 같은 Wi-Fi인데도 안 돼요.**
이 앱은 Wi-Fi가 아니라 **Tailscale**로 연결합니다. 둘 다 Tailscale에
로그인돼 있어야 하고, 앱에는 `tailscale ip -4`로 나온 IP를 넣어야 합니다.

**Q. 알림이 안 와요.**
현재 알림은 *로컬* 알림이라 앱이 켜져 있거나 백그라운드에서 연결이
살아있을 때만 도착합니다. 앱을 완전히 종료하면 알림이 오지 않습니다
(진짜 푸시는 v1.1 예정).

**Q. 매번 직접 켜야 하나요?**
아니요. relay는 launchd 서비스라 **Mac 로그인 시 자동 시작**되고 죽으면
다시 뜹니다. 단, **cmux 앱은 직접 실행**해야 합니다.

---

## 사용자에게 보낼 짧은 안내문

연결이 안 된다는 사람에게 아래를 그대로 전달하세요:

> **cmux Remote 연결 체크 (Mac에서 실행)**
>
> 1. cmux 앱이 켜져 있는지 확인하세요.
> 2. 터미널에 붙여넣기:
>    ```bash
>    SERVICE="gui/$(id -u)/com.genie.cmuxremote"
>    launchctl kickstart -k "$SERVICE"
>    curl -s http://$(tailscale ip -4):4399/v1/health
>    ```
>    → `{"ok":true,...}` 가 나오면 relay 정상입니다.
> 3. 앱(iPhone)과 Mac이 **같은 Tailscale 계정**으로 로그인돼 있는지
>    확인하세요.
> 4. 앱에는 `tailscale ip -4` 로 나온 IP와 포트 `4399` 를 입력하세요.
>
> 그래도 안 되면 `tail -n 40 ~/.cmuxremote/log/stderr.log` 결과를
> 알려주세요.
