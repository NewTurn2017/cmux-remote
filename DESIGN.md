# cmux Remote Design System

## 1. Atmosphere & Identity

cmux Remote is a dense, calm terminal control surface. Its signature is the
Tokyo Night command deck: terminal content stays visually dominant while
controls read as compact physical keycaps layered above it.

## 2. Color

The source of truth is `ios/CmuxRemote/UI/CmuxTheme.swift`.

| Role | Swift token | Value | Usage |
|---|---|---:|---|
| Canvas | `CmuxTheme.canvas` | `#1A1B26` | App background |
| Terminal | `CmuxTheme.terminal` | `#16161E` | Terminal viewport |
| Surface | `CmuxTheme.surface` | `#24283B` | Primary panels |
| Raised surface | `CmuxTheme.surfaceRaised` | `#292E42` | Keycaps and selection |
| Sunken surface | `CmuxTheme.surfaceSunken` | `#1F2335` | Inputs and recessed controls |
| Primary text | `CmuxTheme.ink` | `#C0CAF5` | Controls and labels |
| Terminal text | `CmuxTheme.terminalText` | `#F1F2F8` | Terminal output |
| Muted text | `CmuxTheme.muted` | `#565F89` | Secondary labels |
| Divider | `CmuxTheme.divider` | `#3B4261` | Hairline borders |
| Primary accent | `CmuxTheme.accentGreen` | `#9ECE6A` | Focus, submit, success |
| Warning | `CmuxTheme.accentYellow` | `#E0AF68` | Demo and warning states |
| Error | `CmuxTheme.accentRed` | `#F7768E` | Errors and destructive states |

Do not add raw colors in view code. Add semantic roles to `CmuxTheme` first.

## 3. Typography

| Role | Font | Sizes | Usage |
|---|---|---|---|
| Display | Departure Mono | 9, 10, 11, 12, 14, 16 pt | Keycaps, badges, short labels |
| Body | Geist Mono | 11, 13, 14 pt | Terminal-adjacent copy and inputs |

Use `cmuxDisplay` and `cmuxMono`; preserve Dynamic Type scaling. Controls may
use compact 10–12 pt display labels, while editable and readable body text
stays at 14 pt.

## 4. Spacing & Layout

Spacing follows a 4 pt base: 4, 8, 12, 16, 20, and 24 pt. The workspace is a
full-window shell with the terminal as the scroll owner and header/accessory
controls overlaid above it.

- Compact width: retain the two-row shortcut grid and stacked input actions.
- Landscape iPad windows at least 700 pt wide: use a compact command deck with
  one input/action row and one horizontally distributed shortcut row.
- The iPad landscape accessory should stay at or below 15% of window height
  when no feedback message is visible.
- iPad support is native and full-screen; compatibility-mode phone framing is
  not an accepted layout.
- The terminal remains full width and receives measured top/bottom insets equal
  to the visible overlays.

## 5. Components

### Terminal accessory panel

- **Structure**: command/live input, utility actions, submit action, feedback,
  terminal shortcut keys.
- **Variants**: compact phone stack; regular-width tablet command deck.
- **Spacing**: 4 pt shortcut gaps; compact iPad uses no vertical row gap and
  horizontal-only 8 pt outer padding; stacked layouts use 12 pt outer padding.
- **States**: idle, focused, live input, sending, success feedback, error.
- **Accessibility**: 44 pt minimum primary touch targets where space permits;
  every key has an accessibility label and identifier; hardware keyboard and
  VoiceOver order follow the visual order.
- **Motion**: no decorative motion; keyboard transitions follow the system.
- **Layout**: bottom overlay; the terminal owns scrolling.

### Header control

- **Structure**: navigation square, workspace identity, battery badge, drawer.
- **Variants**: surface chip row visible when the keyboard is inactive.
- **States**: idle, demo, busy surface mutation, error.
- **Accessibility**: labeled buttons and non-color status cues.

### Keycap

- **Structure**: centered display label or SF Symbol on a raised/sunken surface.
- **States**: default, active, disabled, loading.
- **Accessibility**: explicit action label; minimum readable contrast.

## 6. Motion & Interaction

Use system keyboard and sheet motion. App-owned transitions use SwiftUI spring
or 100–300 ms ease timing and must communicate navigation or state. Do not add
decorative animation or animate layout dimensions continuously.

## 7. Depth & Surface

The strategy is mixed tonal shift plus hairline borders. Nested surfaces step
from terminal to panel to raised/sunken controls. `CmuxTheme.divider` provides
one-pixel containment; tinted hard shadows are reserved for floating overlays.

## 8. Accessibility Constraints & Accepted Debt

Target WCAG 2.2 AA-equivalent contrast, visible focus, VoiceOver labels,
Dynamic Type, hardware keyboard operation, and 44 pt primary touch targets.
Compact secondary terminal keys may remain 34 pt high because the dense remote
control surface exposes twelve simultaneous shortcuts; labels and spacing must
remain unambiguous.

| Item | Location | Why accepted | Exit |
|---|---|---|---|
| 34 pt secondary shortcut keys | Workspace terminal accessory | Density is required to preserve terminal space and simultaneous shortcuts | Revisit with user-configurable shortcut sets |
