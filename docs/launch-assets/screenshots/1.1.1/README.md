# cmux Remote 1.1.1 App Store Screenshots

Marketing screenshot package for App Store Connect release `1.1.1 (17)`.

## Deliverables

| Device | Locale | Count | Dimensions | Directory |
|---|---:|---:|---:|---|
| iPhone 6.9-inch | Korean | 5 | 1320x2868 | `iphone-6.9/ko/` |
| iPhone 6.9-inch | English | 5 | 1320x2868 | `iphone-6.9/en/` |
| iPad 13-inch | Korean | 3 | 2752x2064 | `ipad-13/ko/` |
| iPad 13-inch | English | 3 | 2752x2064 | `ipad-13/en/` |

The four `review/` contact sheets are QA aids and must not be uploaded to ASC.

## iPhone Story

| Order | Feature | Korean headline | English headline |
|---:|---|---|---|
| 1 | Remote command center | Mac의 cmux를 손안에서 | Your Mac terminal. In your hand. |
| 2 | Truecolor selection and copy | 색은 그대로, 선택은 정밀하게 | True color. Precise selection. |
| 3 | Uploads and terminal Files viewer | 터미널의 파일을 바로 열어보세요 | Terminal files. On your phone. |
| 4 | Compact command deck | 명령은 빠르게, 터미널은 더 넓게 | Faster commands. More terminal room. |
| 5 | Private Tailscale connection | 내 네트워크 안에서 안전하게 | Private by design. Yours end to end. |

## iPad Story

| Order | Feature | Korean headline | English headline |
|---:|---|---|---|
| 1 | Full-width terminal | 넓은 터미널을 위한 진짜 iPad 작업공간 | A true iPad workspace for wide terminals |
| 2 | Files popover | 파일은 터미널 옆에서 바로 확인 | Preview files beside your terminal |
| 3 | Workspace overview | 모든 워크스페이스를 한눈에 | Every workspace at a glance |

## ASC Upload Order

1. Open the `1.1.1` version in App Store Connect.
2. Open **View All Sizes in Media Manager**.
3. Upload each locale's five files to the unified **iPhone 6.9-inch** slot in filename order.
4. Upload each locale's three files to the **iPad Pro (6th Gen) 12.9/13-inch** slot in filename order.
5. Leave legacy iPhone 6.5-inch slots empty when the 6.9-inch unified slot is accepted.
6. Verify the Korean and English storefronts separately before saving.

Do not upload the `review/` contact sheets.

## Reproduction

```bash
bash screens-src/1.1.1/render.sh
bash screens-src/1.1.1/validate.sh
```

The renderer uses Google Chrome headless and the app's bundled Departure Mono
and Geist Mono fonts. The HTML reconstruction follows the shipping Tokyo Night
theme and only presents features available in build 17.

## Review Evidence

- `review/iphone-6.9-ko-contact-sheet.png`
- `review/iphone-6.9-en-contact-sheet.png`
- `review/ipad-13-ko-contact-sheet.png`
- `review/ipad-13-en-contact-sheet.png`

Validation target:

```text
PASS 16 ASC screenshots and 4 review sheets
```
