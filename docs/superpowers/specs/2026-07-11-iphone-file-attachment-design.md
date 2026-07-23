# iPhone 임의 파일 첨부 (문서 피커) — design

- **Date:** 2026-07-11
- **Status:** Approved (pre-implementation)
- **Area:** `ios/CmuxRemote/Workspace/WorkspaceView.swift` (iOS 전용)
- **Depends on:** 없음 (relay 백엔드 무변경)

## Problem

현재 iPhone 앱의 입력바에서 첨부할 수 있는 건 **사진 라이브러리 이미지**(`PhotosPicker`)와
**클립보드 붙여넣기**뿐이다. 사용자는 임의의 파일(PDF, 코드, zip, 로그 등)을 Files 앱에서
골라 워크스페이스에 보내고 싶어 한다 — 예를 들어 터미널의 Claude/Codex에게 그 파일 경로를
넘기기 위해서.

## 이미 존재하는 것 (핵심)

무거운 백엔드는 **이미 범용으로 구현되어 있다.** 이미지 전용이 아니다.

- relay: `RelayFileUploadService` (`Sources/RelayServer/HostServices.swift`) 가 JSON-RPC
  `file.upload` 를 처리한다. `filename` + `mime_type` + `data_base64` 를 받아 base64 디코드 후
  `~/Downloads/cmux-remote/<filename>` 에 `.atomic` 으로 쓰고 `{filename, path, bytes, mime_type}`
  를 돌려준다. 상한은 `maxBytes = 12 MiB`. WebSocket 프레임 상한은 `maxWebSocketFrameBytes = 24 MiB`
  (base64 ~33% 팽창을 감안해도 12 MiB 파일은 여유).
- iOS: `SurfaceStore.uploadFile(data:filename:mimeType:)` (`ios/CmuxRemote/Stores/SurfaceStore.swift`)
  가 그 `file.upload` RPC 를 호출한다 — **이미 임의 데이터/파일명/MIME 를 받는 범용 함수.**
- iOS: `attachPhoto(_:)` 는 `이미지 준비 → uploadFile → appendPathToDraft(경로)` 흐름
  (`WorkspaceView.swift`). `appendPathToDraft` 와 `uploadFile` 은 그대로 재사용 가능하다.

따라서 **없는 건 iOS에서 "임의 파일을 고르는 UI" 하나뿐**이다. relay 변경은 없다.

## Goals

- 입력바의 첨부 진입점을 **버튼 하나(Menu)** 로 통합: 탭하면 `사진` / `파일` 선택지.
- `파일` 선택 시 iOS 문서 피커(`.fileImporter`)로 **모든 종류의 파일**을 고를 수 있다
  (iCloud Drive · On My iPhone · 서드파티 클라우드 제공자).
- 고른 파일은 사진과 **동일한 동작**: Mac `~/Downloads/cmux-remote/` 에 저장하고, 저장된
  Mac 경로를 입력창 draft 에 삽입한다.
- 저장 파일명은 **타임스탬프 접두**로 충돌/덮어쓰기를 방지한다.

## Non-goals (YAGNI)

- 다중 파일 동시 첨부 (단일 파일만; `allowsMultipleSelection: false`).
- 12 MiB 초과 대형 파일 청크 업로드 / 상한 상향.
- 파일 내용 인라인 붙여넣기, 미리보기 썸네일.
- relay/프로토콜/저장 위치 변경.

## Design

### UI — 통합 첨부 메뉴

기존 `PhotoAttachButton` 을 `AttachMenuButton` 으로 교체한다. SwiftUI `Menu` 안에 두 액션:

- **사진** — `showPhotoPicker = true`
- **파일** — `showFilePicker = true`

`PhotosPicker(selection:)` 뷰를 직접 메뉴 항목으로 쓰는 대신, 입력바에 boolean-presented
모디파이어 두 개를 붙여 프로그램적으로 띄운다 (iOS 17+):

```
.photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
.fileImporter(isPresented: $showFilePicker,
              allowedContentTypes: [.item],
              allowsMultipleSelection: false) { result in ... }
```

버튼 외형/크기는 기존 `PhotoAttachButton` 스타일(40×36, `surfaceRaised`, `RoundedRectangle`,
`divider` 테두리)을 유지하고 SF Symbol 은 `plus`(승인 목업의 `[ + ]`)로. 접근성 식별자
`CommandAttachButton`, 라벨 `AttachMenuButton` = "Attach photo or file"; 메뉴 항목 라벨
`사진`(`photo`)·`파일`(`doc`). 첨부 진행 중(`attachmentInFlight`)엔 `plus` 대신 `ProgressView`.

### 데이터 흐름 — 파일 첨부

신규 `attachFile(_ url: URL) async` (사진 흐름과 대칭):

1. **보안 스코프 접근**: 문서 피커가 돌려준 URL 은 security-scoped 이므로
   `let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }`.
2. **크기 사전 체크**: `URLResourceValues.fileSize` 로 바이트 확인. `> 12 MiB` 면 파일을 열지도
   않고 종료. 단 `fileSize` 는 옵셔널이고 provider 가 값을 안 주거나 실제와 다를 수 있으므로
   **이것만으로는 상한이 보장되지 않는다** — 아래 로드 단계에서 다시 강제한다.
3. **바이트 로드(상한 강제)**: `AttachmentReader.readBounded(from:limit:)` 로 **최대 12 MiB + 1**
   까지만 읽는다. 그보다 크면 `nil` 을 돌려주고 업로드하지 않는다. 사전 체크를 통과했든 아니든
   메모리에 올라가는 양이 상한을 넘지 않는다(업로드 시 base64 사본이 한 벌 더 생기므로 중요).
   초과 시 친절한 에러(`composer.failSubmit` 경유, "파일이 너무 큽니다 (최대 12MB)")를 표시.
4. **파일명 = 타임스탬프 접두 + 원본 basename** (아래 규칙).
5. **MIME 추론**: `url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType`
   → 없으면 `application/octet-stream`.
6. `surfaceStore.uploadFile(data:filename:mimeType:)` 호출 (이미지 준비 단계 없음, 원본 바이트).
7. 성공 시 메인 액터에서 `appendPathToDraft(uploaded.path)` + `commandFieldFocused = true`
   + `composer.clearError()`. 실패 시 `composer.failSubmit(error)`.
8. `attachmentInFlight` 스피너를 사진과 공유 (동시 첨부 중 버튼 비활성).

### 저장 파일명 규칙 (타임스탬프 접두)

- 최종 형식: `<yyyyMMdd-HHmmss>-<basename>`, 예: `20260711-013245-report.pdf`.
- **타임스탬프는 relay(`RelayFileUploadService.uniqueFilename`)가 붙인다.** 구현 중 확인 결과
  relay 가 모든 업로드에 자체 타임스탬프를 이미 붙이므로, iOS 는 타임스탬프를 붙이지 않고
  **sanitize 된 원본 basename 만** 보낸다(이중 타임스탬프 방지).
- iOS basename sanitize(`AttachmentNaming.sanitizedBasename`): 마지막 경로 컴포넌트만 취해
  경로 구분자/제어문자 제거(디렉터리 이탈 방지), 비면 `file`. 확장자 보존.
- relay 측 교정(구현 중 발견한 버그 수정): (1) 원본 파일명을 **그대로 존중**하고 확장자를
  강제로 덧붙이지 않는다(예전엔 확장자 없는 `Dockerfile` 에 `.jpg` 를 붙였음). (2) 이름이
  비었을 때만 `upload.<ext>` 로 합성하되 `<ext>` 는 MIME 에서 `UTType` 으로 추론. (3) sanitize 를
  `NSString.lastPathComponent` 로 바꿔 빈 입력이 cwd 로 해석되던 누수 제거.
- 결과 경로: `~/Downloads/cmux-remote/20260711-013245-report.pdf`. 타임스탬프로 매 업로드가
  고유 → 덮어쓰기 없음.

### Components / 경계

| 유닛 | 역할 | 의존 |
|---|---|---|
| `AttachMenuButton` (View) | 첨부 메뉴 표시, 두 상태 flag 토글 | 부모의 `showPhotoPicker`/`showFilePicker` 바인딩 |
| `.fileImporter` 결과 핸들러 | 선택 URL → `attachFile` 호출, 취소/에러 처리 | — |
| `attachFile(_:)` | URL → 크기체크 → 바이트 → uploadFile → draft 삽입 | `AttachmentReader`, `surfaceStore.uploadFile`, `appendPathToDraft` |
| `AttachmentReader.readBounded(from:limit:)` | 상한까지만 읽고 초과 시 `nil` | Foundation 파일 IO만 (테스트 대상) |
| `sanitizedAttachmentFilename(_:)` (순수 헬퍼) | basename sanitize + 타임스탬프 접두 | 없음 (테스트 대상) |

`uploadFile` / `appendPathToDraft` / `attachmentTimestamp` 는 기존 그대로. `attachPhoto` 는
`prepareImageAttachment` 를 계속 쓰되, 파일 경로만 새로 분기.

## Error handling

- **취소**: `.fileImporter` 가 취소되면 아무 동작 없음.
- **12 MiB 초과**: 업로드 전 차단 + "파일이 너무 큽니다 (최대 12MB)" 메시지.
- **보안 스코프 접근 실패 / 읽기 실패**: `composer.failSubmit(error)` 로 표면화.
- **relay 측 에러**(`file.upload` 실패, 예: 상한/쓰기 실패): 기존 `uploadFile` 의 catch 가
  `inputStatus = .failed(...)` + throw → 호출부에서 `failSubmit`.

## 안전 · 테스트 가능성 제약 (중요)

iOS 앱은 개발 중 실기기/시뮬레이터 e2e 테스트가 어렵다(운영자가 원격). 따라서 **되돌리기 쉽고
회귀 위험이 낮은 방식**으로 간다:

- **순수 로직 최대화**: 파일명 sanitize/타임스탬프, MIME 추론을 UI 밖 순수 함수로 빼서
  단위 테스트로 검증(앱 실행 없이 확인 가능한 부분을 최대로).
- **기존 사진 흐름 무변경 보장**: `attachPhoto`/`prepareImageAttachment`/`uploadFile`/
  `appendPathToDraft` 는 건드리지 않고, 파일 경로만 새 분기로 추가. 사진 첨부가 깨질 여지 차단.
- **검증된 경로 재사용**: 업로드는 이미 동작하는 `uploadFile` RPC 를 그대로 사용.
- **relay 무변경**: 서버측 회귀 0. 임의 파일 업로드는 relay 단위 테스트로 이미 커버됨 →
  구현 중 `swift test` 로 재확인(이건 로컬에서 실행 가능).
- **실패 안전(fail-safe)**: 크기 초과·읽기 실패·취소는 모두 조용히 또는 명확한 에러로 처리하고
  입력창 상태를 오염시키지 않는다.

## Testing

- **단위 테스트** (신규, `CmuxRemoteTests`): `sanitizedAttachmentFilename(_:)` —
  - 일반 파일명 유지 + 타임스탬프 접두 형식,
  - 경로 구분자/제어문자 제거,
  - 빈/확장자만 있는 이름 → `file` 대체,
  - 확장자 보존.
- **MIME 추론**: 헬퍼로 분리해 `.pdf`, 확장자 없는 파일(→ octet-stream) 케이스 테스트.
- **상한 읽기** (신규, `AttachmentReaderTests`): 상한 미만/정확히 상한/상한 +1 바이트/상한을
  크게 초과/빈 파일/없는 파일 케이스. 임시 파일로 실제 파일 IO 를 돌린다.
- **relay**: `RelayFileUploadService` 는 이미 임의 파일 업로드 테스트가 존재하므로 추가 불필요.
- **수동 검증**: iOS 시뮬레이터/실기기에서 Files 앱의 PDF·텍스트·확장자 없는 파일을 첨부 →
  Mac `~/Downloads/cmux-remote/` 에 타임스탬프 파일 생성 + draft 에 경로 삽입 확인.

## Rollout notes

- iOS 전용 변경 → **App Store 재빌드/재제출 필요.** relay 무변경.
- `Info.plist`: 문서 피커는 별도 권한 문자열이 필요 없다(사용자가 명시적으로 파일 선택).
  iCloud/Documents 관련 entitlement 가 필요한지는 구현 시 빌드로 확인.
- 이 브랜치(`feat/iphone-file-attachment`)는 `main` 기반이며, 릴리스 빌드 타입체커 수정
  (PR #11, `fix/inbox-notification-typecheck`)과 독립적이다. iOS 변경이라 해당 수정과
  충돌하지 않는다.
