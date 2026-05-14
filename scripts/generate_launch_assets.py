#!/usr/bin/env python3
"""Generate launch-time visual assets for CmuxRemote.

Inputs:
  - docs/launch-assets/source/cmux-remote-app-icon-gpt.png
  - docs/launch-assets/source/cmux-remote-brandmark-transparent.png (optional)

Outputs:
  - ios/CmuxRemote/Assets.xcassets/AppIcon.appiconset/*
  - docs/launch-assets/screenshots/app-store-6.9/*.png
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ICON_SOURCE = ROOT / "docs/launch-assets/source/cmux-remote-app-icon-gpt.png"
DEFAULT_MARK_SOURCE = ROOT / "docs/launch-assets/source/cmux-remote-brandmark-transparent.png"
APPICON_DIR = ROOT / "ios/CmuxRemote/Assets.xcassets/AppIcon.appiconset"
SCREENSHOT_DIR = ROOT / "docs/launch-assets/screenshots/app-store-6.9"
FINAL_ICON_SOURCE = ROOT / "docs/launch-assets/source/cmux-remote-app-icon-final.png"
FINAL_MARK_SOURCE = ROOT / "docs/launch-assets/source/cmux-remote-brandmark-final.png"
SCREEN_W = 1320
SCREEN_H = 2868


def font(size: int, weight: str = "regular", mono: bool = False) -> ImageFont.FreeTypeFont:
    if mono:
        for path in (
            "/System/Library/Fonts/Menlo.ttc",
            "/System/Library/Fonts/SFNSMono.ttf",
            "/System/Library/Fonts/Supplemental/Courier New.ttf",
        ):
            if Path(path).exists():
                return ImageFont.truetype(path, size=size, index=1 if weight == "bold" else 0)
    candidates = [
        "/System/Library/Fonts/AppleSDGothicNeo.ttc",
        "/System/Library/Fonts/Supplemental/AppleGothic.ttf",
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    ]
    index = {"regular": 4, "medium": 5, "semibold": 6, "bold": 7}.get(weight, 4)
    for path in candidates:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size=size, index=index)
            except OSError:
                return ImageFont.truetype(path, size=size)
    return ImageFont.load_default()


F = {
    "title": font(76, "bold"),
    "subtitle": font(35, "semibold"),
    "h1": font(44, "bold"),
    "h2": font(30, "bold"),
    "body": font(26, "medium"),
    "small": font(21, "semibold"),
    "tiny": font(18, "semibold"),
    "mono": font(26, "regular", mono=True),
    "mono_big": font(34, "regular", mono=True),
    "mono_bold": font(26, "bold", mono=True),
}


INK = (10, 13, 24)
MUTED = (119, 138, 148)
CANVAS = (237, 245, 245)
CARD = (255, 255, 255)
DIVIDER = (213, 224, 226)
TERMINAL = (12, 14, 19)
PANEL = (25, 28, 34)
CHIP = (43, 46, 54)
ACCENT = (122, 219, 117)
GREEN = (87, 255, 136)


def rr(draw: ImageDraw.ImageDraw, box, radius, fill, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def fit_text(draw: ImageDraw.ImageDraw, text: str, fnt, max_w: int) -> str:
    out = text
    while draw.textlength(out, font=fnt) > max_w and len(out) > 2:
        out = out[:-2] + "…"
    return out


def draw_text(draw: ImageDraw.ImageDraw, xy, text: str, fnt, fill, max_w=None, spacing=8):
    if not max_w:
        draw.multiline_text(xy, text, font=fnt, fill=fill, spacing=spacing)
        return
    words = text.split(" ")
    lines: list[str] = []
    cur = ""
    for word in words:
        trial = f"{cur} {word}".strip()
        if draw.textlength(trial, font=fnt) <= max_w or not cur:
            cur = trial
        else:
            lines.append(cur)
            cur = word
    if cur:
        lines.append(cur)
    draw.multiline_text(xy, "\n".join(lines), font=fnt, fill=fill, spacing=spacing)


def gradient_bg(top=(6, 9, 16), bottom=(18, 28, 24)) -> Image.Image:
    img = Image.new("RGB", (SCREEN_W, SCREEN_H), top)
    px = img.load()
    for y in range(SCREEN_H):
        t = y / (SCREEN_H - 1)
        col = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
        for x in range(SCREEN_W):
            px[x, y] = col
    return img


def paste_mark(img: Image.Image, mark_path: Path, box: tuple[int, int, int, int], opacity: float = 1):
    if not mark_path.exists():
        return
    mark = Image.open(mark_path).convert("RGBA")
    mark.thumbnail((box[2] - box[0], box[3] - box[1]), Image.Resampling.LANCZOS)
    if opacity < 1:
        a = mark.getchannel("A").point(lambda p: int(p * opacity))
        mark.putalpha(a)
    x = box[0] + ((box[2] - box[0]) - mark.width) // 2
    y = box[1] + ((box[3] - box[1]) - mark.height) // 2
    img.alpha_composite(mark, (x, y))


def clean_brandmark(source: Path) -> Path:
    if not source.exists():
        return source
    mark = Image.open(source).convert("RGBA")
    mp = mark.load()
    for y in range(mark.height):
        for x in range(mark.width):
            r, g, b, a = mp[x, y]
            mx, mn = max(r, g, b), min(r, g, b)
            # Remove generated checkerboard or light-gray matte backgrounds.
            if mx > 178 and (mx - mn) < 34:
                mp[x, y] = (r, g, b, 0)
            else:
                mp[x, y] = (r, g, b, a)
    FINAL_MARK_SOURCE.parent.mkdir(parents=True, exist_ok=True)
    mark.save(FINAL_MARK_SOURCE, optimize=True)
    return FINAL_MARK_SOURCE


def phone_shell(base: Image.Image, x=90, y=500, w=1140, h=2180, fill=TERMINAL) -> ImageDraw.ImageDraw:
    d = ImageDraw.Draw(base)
    shadow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    rr(sd, (x + 8, y + 34, x + w + 8, y + h + 34), 96, (0, 0, 0, 100))
    base.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28)))
    rr(d, (x, y, x + w, y + h), 96, (3, 5, 9), outline=(45, 49, 58), width=5)
    rr(d, (x + 24, y + 24, x + w - 24, y + h - 24), 74, fill)
    # Dynamic island + status bar.
    rr(d, (x + w // 2 - 118, y + 44, x + w // 2 + 118, y + 88), 23, (0, 0, 0))
    d.text((x + 84, y + 50), "9:41", font=F["small"], fill=(242, 244, 247))
    d.text((x + w - 205, y + 50), "Wi‑Fi  87", font=F["tiny"], fill=(242, 244, 247))
    return d


def nav_dark(d, x, y, w, title="cmux-iphone", chip="omx", path=".../dev/side/cmux-iphone"):
    rr(d, (x + 66, y + 132, x + 138, y + 204), 24, (30, 34, 42))
    d.text((x + 86, y + 144), "‹", font=F["h1"], fill=(190, 198, 208))
    rr(d, (x + 190, y + 132, x + w - 190, y + 204), 34, (54, 57, 68))
    d.text((x + 248, y + 147), "●", font=F["small"], fill=(188, 194, 204))
    d.text((x + 292, y + 145), fit_text(d, title, F["h2"], w - 570), font=F["h2"], fill=(190, 194, 204))
    rr(d, (x + w - 138, y + 132, x + w - 66, y + 204), 24, (30, 34, 42))
    for gx in (x + w - 115, x + w - 90):
        for gy in (y + 154, y + 179):
            rr(d, (gx, gy, gx + 14, gy + 14), 3, (190, 198, 208))
    rr(d, (x + 66, y + 246, x + 188, y + 310), 30, (54, 57, 68))
    d.text((x + 98, y + 263), chip, font=F["small"], fill=(224, 229, 236))
    rr(d, (x + 218, y + 246, x + w - 66, y + 310), 30, (19, 22, 29))
    d.text((x + 248, y + 260), path, font=F["body"], fill=(168, 174, 184))


def composer(d, x, y, w, bottom):
    panel_h = 315
    rr(d, (x + 52, bottom - panel_h, x + w - 52, bottom - 46), 56, (28, 31, 38))
    rr(d, (x + 104, bottom - panel_h + 60, x + w - 270, bottom - panel_h + 136), 38, (36, 39, 47))
    d.text((x + 152, bottom - panel_h + 83), "터미널에 입력", font=F["body"], fill=(83, 89, 101))
    for i in range(2):
        cx = x + 118 + i * 130
        rr(d, (cx - 42, bottom - panel_h + 172, cx + 42, bottom - panel_h + 256), 42, (43, 47, 56))
        if i == 0:
            rr(d, (cx - 23, bottom - panel_h + 202, cx + 23, bottom - panel_h + 226), 5, None, outline=(185, 193, 205), width=3)
            for gx in range(cx - 14, cx + 18, 10):
                d.line((gx, bottom - panel_h + 209, gx + 2, bottom - panel_h + 209), fill=(185, 193, 205), width=2)
            d.line((cx - 10, bottom - panel_h + 219, cx + 10, bottom - panel_h + 219), fill=(185, 193, 205), width=2)
        else:
            d.polygon(
                [
                    (cx - 28, bottom - panel_h + 214),
                    (cx - 12, bottom - panel_h + 198),
                    (cx + 28, bottom - panel_h + 198),
                    (cx + 28, bottom - panel_h + 230),
                    (cx - 12, bottom - panel_h + 230),
                ],
                outline=(185, 193, 205),
                fill=None,
            )
            d.line((cx - 2, bottom - panel_h + 206, cx + 12, bottom - panel_h + 220), fill=(185, 193, 205), width=3)
            d.line((cx + 12, bottom - panel_h + 206, cx - 2, bottom - panel_h + 220), fill=(185, 193, 205), width=3)
    rr(d, (x + w - 330, bottom - panel_h + 172, x + w - 112, bottom - panel_h + 256), 42, (45, 49, 58))
    d.text((x + w - 286, bottom - panel_h + 194), "➤  전송", font=F["body"], fill=(207, 213, 222))
    sy = bottom - 78
    for sx, lab in [
        (x + 102, "esc"),
        (x + 226, "줄바꿈"),
        (x + 405, "/"),
        (x + 535, "$"),
        (x + 655, "enter"),
        (x + 790, "↑"),
        (x + 850, "↓"),
    ]:
        d.text((sx, sy), lab, font=F["small"], fill=(183, 190, 201))


def workspace_ui(base: Image.Image, x, y, w, h, selected=True):
    d = ImageDraw.Draw(base)
    rr(d, (x, y, x + w, y + h), 70, CANVAS)
    d.text((x + 88, y + 130), "‹", font=F["h1"], fill=(135, 150, 158))
    d.text((x + 395, y + 122), "Workspaces", font=F["h1"], fill=INK)
    d.text((x + 456, y + 178), "Relay connected", font=F["small"], fill=MUTED)
    rr(d, (x + w - 162, y + 104, x + w - 66, y + 200), 48, (248, 250, 250))
    d.text((x + w - 132, y + 112), "+", font=F["h1"], fill=INK)
    rr(d, (x + 66, y + 285, x + w - 66, y + 382), 34, CARD)
    d.ellipse((x + 118, y + 315, x + 148, y + 345), outline=INK, width=5)
    d.line((x + 142, y + 340, x + 158, y + 356), fill=INK, width=5)
    d.text((x + 188, y + 306), "Search", font=F["h2"], fill=(188, 190, 198))
    d.text((x + 66, y + 455), "Workspaces", font=F["h2"], fill=MUTED)
    cards = [
        ("따능에이전트 / API동시작업", "4 surfaces"),
        ("신규 강의 런칭", "3 surfaces"),
        ("마케팅 자동화", "2 surfaces"),
        ("cmux-iphone", "2 surfaces"),
        ("디자인 리뷰", "1 surface"),
    ]
    cy = y + 522
    for idx, (name, surfaces) in enumerate(cards):
        rr(d, (x + 66, cy, x + w - 66, cy + 132), 34, CARD)
        rr(d, (x + 108, cy + 28, x + 184, cy + 104), 20, INK)
        d.text((x + 130, cy + 49), ">_", font=F["small"], fill=CARD)
        d.text((x + 214, cy + 35), fit_text(d, name, F["h2"], w - 430), font=F["h2"], fill=INK)
        d.text((x + 214, cy + 83), surfaces, font=F["body"], fill=MUTED)
        if (idx == 0 and selected) or idx == 3:
            d.ellipse((x + w - 145, cy + 61, x + w - 125, cy + 81), fill=ACCENT)
        else:
            d.text((x + w - 150, cy + 58), f"#{idx+1}", font=F["tiny"], fill=(186, 196, 202))
        cy += 162
    rr(d, (x + 70, y + h - 180, x + w - 70, y + h - 70), 54, (248, 250, 250))
    for i, (label, on) in enumerate([("Workspaces", True), ("Active", False), ("Inbox", False), ("Settings", False)]):
        cx = x + 160 + i * 260
        if on:
            rr(d, (cx - 78, y + h - 170, cx + 78, y + h - 78), 46, (232, 242, 246))
        d.text((cx - 54, y + h - 135), label, font=F["tiny"], fill=INK if on else MUTED)


def screenshot_workspaces(mark_path: Path):
    img = gradient_bg((229, 249, 243), (180, 220, 215)).convert("RGBA")
    d = ImageDraw.Draw(img)
    d.text((88, 96), "Mac의 cmux를", font=F["title"], fill=INK)
    d.text((88, 184), "iPhone에서 바로 제어", font=F["title"], fill=INK)
    d.text((92, 294), "작업공간·서피스·알림을 하나의 리모트 컨트롤로", font=F["subtitle"], fill=(67, 86, 93))
    paste_mark(img, mark_path, (950, 110, 1210, 370), opacity=0.9)
    phone_shell(img, y=520, fill=CANVAS)
    workspace_ui(img, 114, 544, 1092, 2132)
    return img.convert("RGB")


def screenshot_terminal(mark_path: Path):
    img = gradient_bg((5, 7, 12), (10, 20, 16)).convert("RGBA")
    d = ImageDraw.Draw(img)
    d.text((88, 96), "손안의 원격 터미널", font=F["title"], fill=(245, 248, 250))
    d.text((92, 294), "스크롤, 입력, 단축키까지 모바일에 맞게", font=F["subtitle"], fill=(166, 179, 188))
    paste_mark(img, mark_path, (990, 105, 1225, 340), opacity=0.75)
    phone_shell(img, y=500, fill=TERMINAL)
    x, y, w, h = 90, 500, 1140, 2180
    nav_dark(d, x, y, w, title="요술마켓", chip="omx", path=".../dev/active/shop-cosmetics")
    lines = [
        "● Ultraview round 2: all 4 fixes pushed",
        "  └ gh pr view 37 --json url,state,mergeStateStatus",
        "",
        "GET /me/wallet 200 in 37ms",
        "GET /api/workspaces 200 in 42ms",
        "",
        "User answered Claude questions:",
        "  └ handoff project slug -> withgenie",
        "",
        "$ git status --short",
        "  M ios/CmuxRemote/WorkspaceView.swift",
        "  M ios/CmuxRemote/TerminalView.swift",
        "",
        "$ omx handoff-save --summary launch-assets",
    ]
    ty = y + 360
    for line in lines:
        color = ACCENT if line.startswith(("GET", "$", "●")) else (142, 238, 139)
        d.text((x + 70, ty), line, font=F["mono"], fill=color)
        ty += 42
    rr(d, (x + w - 178, y + h - 770, x + w - 70, y + h - 662), 54, (32, 35, 42), outline=(58, 63, 74), width=2)
    d.text((x + w - 140, y + h - 755), "↓", font=F["h1"], fill=(220, 225, 232))
    composer(d, x, y, w, y + h - 36)
    return img.convert("RGB")


def screenshot_shortcuts(mark_path: Path):
    img = gradient_bg((12, 14, 22), (17, 28, 30)).convert("RGBA")
    d = ImageDraw.Draw(img)
    d.text((88, 96), "입력은 길게,", font=F["title"], fill=(245, 248, 250))
    d.text((88, 184), "조작은 즉시", font=F["title"], fill=(245, 248, 250))
    d.text((92, 294), "esc · 줄바꿈 · enter · ↑↓ 같은 터미널 키를 한 탭으로", font=F["subtitle"], fill=(166, 179, 188))
    phone_shell(img, y=500, fill=TERMINAL)
    x, y, w, h = 90, 500, 1140, 2180
    nav_dark(d, x, y, w, title="cmux-iphone", chip="omx", path=".../dev/side/cmux-iphone")
    rr(d, (x + 70, y + 370, x + w - 70, y + 995), 42, (16, 18, 24), outline=(65, 255, 123), width=10)
    d.text((x + 105, y + 410), "키보드가 올라와도\n터미널과 입력창이 함께 보입니다.", font=F["h1"], fill=(218, 231, 229), spacing=18)
    d.text((x + 105, y + 610), "명령은 작성하고, 방향키/enter는 즉시 전송합니다.", font=F["body"], fill=(138, 156, 166), spacing=10)
    composer(d, x, y, w, y + h - 330)
    # Draw simplified keyboard.
    kb_y = y + h - 600
    rr(d, (x + 24, kb_y, x + w - 24, y + h - 28), 42, (184, 188, 194))
    rows = ["ㅂㅈㄷㄱㅅㅛㅕㅑㅐㅔ", "ㅁㄴㅇㄹㅎㅗㅓㅏㅣ", "⇧ㅋㅌㅊㅍㅠㅜㅡ⌫"]
    ry = kb_y + 86
    for row in rows:
        cx = x + 62
        for ch in row:
            ww = 82
            rr(d, (cx, ry, cx + ww, ry + 90), 18, (245, 247, 250))
            d.text((cx + 27, ry + 18), ch, font=F["h2"], fill=(0, 0, 0))
            cx += ww + 20
        ry += 126
    return img.convert("RGB")


def screenshot_inbox(mark_path: Path):
    img = gradient_bg((235, 249, 245), (204, 229, 226)).convert("RGBA")
    d = ImageDraw.Draw(img)
    d.text((88, 96), "작업 흐름을 놓치지 않게", font=F["title"], fill=INK)
    d.text((92, 294), "각 워크스페이스 알림을 Inbox에서 한 번에 확인", font=F["subtitle"], fill=(67, 86, 93))
    phone_shell(img, y=500, fill=CANVAS)
    x, y, w, h = 90, 500, 1140, 2180
    rr(d, (x + 24, y + 24, x + w - 24, y + h - 24), 74, CANVAS)
    d.text((x + 80, y + 132), "Inbox", font=F["title"], fill=INK)
    d.text((x + 82, y + 224), "오늘 완료된 원격 작업", font=F["body"], fill=MUTED)
    notices = [
        ("요술마켓", "PR #37 checks passed", "방금 전", ACCENT),
        ("cmux-iphone", "실기기 빌드 설치 완료", "8분 전", (81, 150, 244)),
        ("강의 자동화", "handoff-save 생성됨", "22분 전", (255, 180, 73)),
        ("디자인 리뷰", "screenshot asset exported", "1시간 전", (178, 125, 255)),
    ]
    cy = y + 330
    for project, msg, time, color in notices:
        rr(d, (x + 66, cy, x + w - 66, cy + 170), 36, CARD)
        d.ellipse((x + 110, cy + 50, x + 170, cy + 110), fill=color)
        d.text((x + 210, cy + 42), project, font=F["h2"], fill=INK)
        d.text((x + 210, cy + 90), msg, font=F["body"], fill=MUTED)
        d.text((x + w - 220, cy + 54), time, font=F["tiny"], fill=(166, 176, 184))
        cy += 204
    rr(d, (x + 70, y + h - 180, x + w - 70, y + h - 70), 54, (248, 250, 250))
    for i, (label, on) in enumerate([("Workspaces", False), ("Active", False), ("Inbox", True), ("Settings", False)]):
        cx = x + 160 + i * 260
        if on:
            rr(d, (cx - 78, y + h - 170, cx + 78, y + h - 78), 46, (232, 242, 246))
        d.text((cx - 54, y + h - 135), label, font=F["tiny"], fill=INK if on else MUTED)
    return img.convert("RGB")


def screenshot_settings(mark_path: Path):
    img = gradient_bg((5, 8, 15), (17, 32, 28)).convert("RGBA")
    d = ImageDraw.Draw(img)
    d.text((88, 96), "설정에서 바로 연결", font=F["title"], fill=(245, 248, 250))
    d.text((92, 294), "Tailscale/Relay 연결 튜토리얼을 앱 안에 포함", font=F["subtitle"], fill=(166, 179, 188))
    phone_shell(img, y=500, fill=CANVAS)
    x, y, w, h = 90, 500, 1140, 2180
    rr(d, (x + 24, y + 24, x + w - 24, y + h - 24), 74, CANVAS)
    d.text((x + 78, y + 130), "설정", font=F["title"], fill=INK)
    rr(d, (x + 66, y + 270, x + w - 66, y + 935), 38, CARD)
    d.text((x + 110, y + 315), "연결 튜토리얼", font=F["h2"], fill=INK)
    steps = [
        ("1", "Mac에서 cmux와 Tailscale을 켭니다."),
        ("2", "릴레이를 실행하고 0.0.0.0:4399로 바인딩합니다."),
        ("3", "iPhone에서 Mac의 100.x IP와 포트를 입력합니다."),
        ("4", "저장 후 연결 다시 시도를 누릅니다."),
    ]
    cy = y + 390
    for num, text in steps:
        d.ellipse((x + 112, cy, x + 162, cy + 50), fill=INK)
        d.text((x + 128, cy + 9), num, font=F["small"], fill=(235, 241, 242))
        d.text((x + 190, cy + 8), text, font=F["body"], fill=INK)
        cy += 118
    rr(d, (x + 66, y + 990, x + w - 66, y + 1350), 38, CARD)
    d.text((x + 110, y + 1035), "Mac 연결", font=F["h2"], fill=MUTED)
    rr(d, (x + 110, y + 1105, x + w - 110, y + 1190), 24, CANVAS)
    d.text((x + 145, y + 1130), "macbook-pro.tailnet.ts.net", font=F["body"], fill=INK)
    rr(d, (x + 110, y + 1240, x + w - 110, y + 1318), 24, (222, 233, 235))
    d.text((x + 145, y + 1262), "↻  저장 후 연결 다시 시도", font=F["body"], fill=INK)
    return img.convert("RGB")


def generate_screenshots(mark_path: Path):
    mark_path = clean_brandmark(mark_path)
    SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)
    shots = [
        ("01-workspaces-remote-control.png", screenshot_workspaces),
        ("02-terminal-live-control.png", screenshot_terminal),
        ("03-keyboard-shortcuts.png", screenshot_shortcuts),
        ("04-inbox-notifications.png", screenshot_inbox),
        ("05-settings-connection-guide.png", screenshot_settings),
    ]
    for name, fn in shots:
        out = SCREENSHOT_DIR / name
        img = fn(mark_path)
        img.save(out, optimize=True)
        print(out.relative_to(ROOT))


def generate_app_icons(source: Path):
    if not source.exists():
        raise SystemExit(f"missing icon source: {source}")
    APPICON_DIR.mkdir(parents=True, exist_ok=True)
    src = Image.open(source).convert("RGBA")
    # GPT drafts sometimes include white checker/corner pixels around the rounded
    # tile. Treat near-white pixels as removable background and composite the
    # glyph over an opaque dark square, because iOS app icons must not contain
    # transparency and iOS applies the final corner mask itself.
    bg = Image.new("RGB", src.size, (8, 10, 16))
    bp = bg.load()
    for y in range(bg.height):
        for x in range(bg.width):
            dx = (x - bg.width / 2) / (bg.width / 2)
            dy = (y - bg.height / 2) / (bg.height / 2)
            r = min(1, math.sqrt(dx * dx + dy * dy))
            bp[x, y] = (
                int(8 + 18 * (1 - r)),
                int(10 + 28 * (1 - r)),
                int(16 + 25 * (1 - r)),
            )
    cleaned = Image.new("RGBA", src.size, (0, 0, 0, 0))
    sp = src.load()
    cp = cleaned.load()
    for y in range(src.height):
        for x in range(src.width):
            r, g, b, a = sp[x, y]
            if r > 242 and g > 242 and b > 242:
                cp[x, y] = (r, g, b, 0)
            else:
                cp[x, y] = (r, g, b, a)
    cleaned = cleaned.filter(ImageFilter.GaussianBlur(0.15))
    opaque = bg
    opaque.paste(cleaned, mask=cleaned.getchannel("A"))
    FINAL_ICON_SOURCE.parent.mkdir(parents=True, exist_ok=True)
    opaque.save(FINAL_ICON_SOURCE, optimize=True)

    specs = [
        ("iphone", "20x20", "2x", 40), ("iphone", "20x20", "3x", 60),
        ("iphone", "29x29", "2x", 58), ("iphone", "29x29", "3x", 87),
        ("iphone", "40x40", "2x", 80), ("iphone", "40x40", "3x", 120),
        ("iphone", "60x60", "2x", 120), ("iphone", "60x60", "3x", 180),
        ("ipad", "20x20", "1x", 20), ("ipad", "20x20", "2x", 40),
        ("ipad", "29x29", "1x", 29), ("ipad", "29x29", "2x", 58),
        ("ipad", "40x40", "1x", 40), ("ipad", "40x40", "2x", 80),
        ("ipad", "76x76", "1x", 76), ("ipad", "76x76", "2x", 152),
        ("ipad", "83.5x83.5", "2x", 167),
        ("ios-marketing", "1024x1024", "1x", 1024),
    ]
    images = []
    for idiom, size, scale, px in specs:
        filename = f"AppIcon-{idiom}-{size.replace('.', '_')}@{scale}.png"
        icon = opaque.resize((px, px), Image.Resampling.LANCZOS)
        icon.save(APPICON_DIR / filename, optimize=True)
        images.append({"idiom": idiom, "size": size, "scale": scale, "filename": filename})

    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (APPICON_DIR / "Contents.json").write_text(json.dumps(contents, ensure_ascii=False, indent=2) + "\n")
    print(APPICON_DIR.relative_to(ROOT))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--icon-source", type=Path, default=DEFAULT_ICON_SOURCE)
    parser.add_argument("--mark-source", type=Path, default=DEFAULT_MARK_SOURCE)
    parser.add_argument("--screenshots-only", action="store_true")
    parser.add_argument("--icons-only", action="store_true")
    args = parser.parse_args()

    if not args.screenshots_only:
        generate_app_icons(args.icon_source)
    if not args.icons_only:
        generate_screenshots(args.mark_source)


if __name__ == "__main__":
    main()
