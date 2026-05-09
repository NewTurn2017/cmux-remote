# M5 — AccessoryBar + ArrowsKeyView + CommandHUD

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Layer Blink-shell-class keyboard ergonomics onto the M4 skeleton — a `UIInputView` AccessoryBar with esc/ctrl/alt/arrows + a fixed symbol set + relay-driven snippets, an `ArrowsKeyView` press-and-drag 4-direction key with auto-repeat, and a `CommandHUD` overlay that listens for `cmd+1…9` / `cmd+[` / `cmd+]` from a hardware keyboard.

**Architecture:** AccessoryBar is a `UIInputView` subclass installed as the focused `UITextField`'s `inputAccessoryView`. The text field is hidden and only exists to (a) raise the system keyboard and (b) become first responder for hardware-keyboard `keyCommands`. Layout descriptors live as pure data (`KBLayout`); the view recycles concrete `KeyButton` subviews on trait changes via `KeyTraits` diffing — pattern adapted from Blink Shell (GPLv3).

**Tech Stack:** SwiftUI 17+ `UIViewRepresentable` to bridge into M4 `WorkspaceView`. Pure UIKit for the AccessoryBar internals (`UIInputView`, `UIControl`, `UIImpactFeedbackGenerator`). No new external SPM deps.

**Branch:** `m5-keyboard` from `main`, after M4 has merged.

**License note:** every commit that adapts a Blink pattern says so in the body. Patterns; not code. There is no copy-paste from Blink Shell sources into this repo.

---

## Spec coverage

- Spec section 6.5 ("Input") — AccessoryBar emits `surface.send_key`/`surface.send_text` via SurfaceStore; haptic on each tap.
- Spec section 9.2 ("AccessoryBar") — left/middle/right layout, snippet middle section, `KeyTraits` mirror of Blink `KBTraits`.
- Spec section 9.3 ("Workspace switcher" — keyboard shortcuts) — CommandHUD pattern adapted from Blink `CommandsHUDView`.

## File map

```
ios/CmuxRemote/Keyboard/
├─ KeyTraits.swift              # task 1
├─ KBLayout.swift               # task 2
├─ KeyButton.swift              # task 3
├─ AccessoryBar.swift           # task 4
├─ AccessoryBarBridge.swift     # task 5 (UIViewRepresentable)
├─ ArrowsKeyView.swift          # task 6
├─ CommandHUDView.swift         # task 7
└─ Snippets.swift               # task 8
```

---

## Task 1 — `KeyTraits`

Mirror of Blink's `KBTraits` OptionSet. Pure data; lets us recompute layouts cheaply.

**Files:**
- Create: `ios/CmuxRemote/Keyboard/KeyTraits.swift`
- Test:   `ios/CmuxRemoteTests/KeyTraitsTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
@testable import CmuxRemote

final class KeyTraitsTests: XCTestCase {
    func testRoundTripAddRemove() {
        var t: KeyTraits = .default
        t.formUnion(.hardwareKeyboardAttached)
        XCTAssertTrue(t.contains(.hardwareKeyboardAttached))
        t.subtract(.portrait)
        XCTAssertFalse(t.contains(.portrait))
    }

    func testDefaultIsPortraitPlusSoftKeyboard() {
        XCTAssertTrue(KeyTraits.default.contains(.portrait))
        XCTAssertTrue(KeyTraits.default.contains(.softKeyboard))
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public struct KeyTraits: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let portrait              = KeyTraits(rawValue: 1 << 0)
    public static let landscape             = KeyTraits(rawValue: 1 << 1)
    public static let softKeyboard          = KeyTraits(rawValue: 1 << 2)
    public static let hardwareKeyboardAttached = KeyTraits(rawValue: 1 << 3)
    public static let floatingKeyboard      = KeyTraits(rawValue: 1 << 4)

    public static let `default`: KeyTraits  = [.portrait, .softKeyboard]
}
```

- [ ] **Step 3: Run + commit (Blink pattern adapted)**

```bash
xcodebuild test -project ios/CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:CmuxRemoteTests/KeyTraitsTests | tail -3
git add ios/CmuxRemote/Keyboard/KeyTraits.swift ios/CmuxRemoteTests/KeyTraitsTests.swift
git commit -m "M5.1: KeyTraits OptionSet (pattern adapted from Blink Shell, GPLv3)"
```

---

## Task 2 — `KBLayout`

Layout descriptor: three ordered key-descriptor lists (left/middle/right). Middle is scrollable. `KeyKind` enumerates which renderer to instantiate.

**Files:**
- Create: `ios/CmuxRemote/Keyboard/KBLayout.swift`
- Test:   `ios/CmuxRemoteTests/KBLayoutTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
import SharedKit
@testable import CmuxRemote

final class KBLayoutTests: XCTestCase {
    func testV10Layout() {
        let layout = KBLayout.v10(snippets: [
            .init(label: "ll", text: "ls -alh\n"),
        ])
        XCTAssertEqual(layout.left.first?.kind, .key(.esc))
        XCTAssertEqual(layout.middle.last?.kind, .snippet(label: "ll", text: "ls -alh\n"))
        XCTAssertEqual(layout.right.first?.kind, .dismissKeyboard)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import SharedKit

public enum KeyKind: Equatable {
    case key(Key)               // esc, tab, etc.
    case modifier(KeyModifier)  // ctrl, alt, shift, cmd
    case symbol(String)         // ~, `, |, etc.
    case arrows                 // ArrowsKeyView
    case dismissKeyboard
    case snippet(label: String, text: String)
}

public struct KeyDescriptor: Equatable {
    public var kind: KeyKind
    public var label: String?
    public var width: CGFloat
    public init(kind: KeyKind, label: String? = nil, width: CGFloat = 36) {
        self.kind = kind; self.label = label; self.width = width
    }
}

public struct KBLayout {
    public var left: [KeyDescriptor]
    public var middle: [KeyDescriptor]
    public var right: [KeyDescriptor]

    public static func v10(snippets: [RelayConfigSnippet]) -> KBLayout {
        let left: [KeyDescriptor] = [
            .init(kind: .key(.esc), label: "esc", width: 44),
            .init(kind: .modifier(.ctrl), label: "ctrl", width: 44),
            .init(kind: .modifier(.alt),  label: "alt",  width: 44),
            .init(kind: .arrows, width: 60),
        ]
        var middle: [KeyDescriptor] = [
            .init(kind: .key(.tab), label: "tab", width: 44),
            .init(kind: .symbol("~"), label: "~"),
            .init(kind: .symbol("`"), label: "`"),
            .init(kind: .symbol("@"), label: "@"),
            .init(kind: .symbol("#"), label: "#"),
            .init(kind: .symbol("/"), label: "/"),
            .init(kind: .symbol("?"), label: "?"),
            .init(kind: .symbol("|"), label: "|"),
            .init(kind: .symbol(":"), label: ":"),
        ]
        for s in snippets {
            middle.append(.init(kind: .snippet(label: s.label, text: s.text),
                                label: s.label, width: max(44, CGFloat(s.label.count * 12))))
        }
        let right: [KeyDescriptor] = [
            .init(kind: .dismissKeyboard, label: "↓", width: 44),
        ]
        return KBLayout(left: left, middle: middle, right: right)
    }
}

public struct RelayConfigSnippet: Equatable {
    public var label: String
    public var text: String
    public init(label: String, text: String) { self.label = label; self.text = text }
}
```

- [ ] **Step 3: Run + commit**

```bash
git add ios/CmuxRemote/Keyboard/KBLayout.swift ios/CmuxRemoteTests/KBLayoutTests.swift
git commit -m "M5.2: KBLayout — left/middle/right descriptor lists"
```

---

## Task 3 — `KeyButton` UIControl

Single-tap key with haptic. Used for `.key`, `.modifier`, `.symbol`, `.snippet`.

**Files:**
- Create: `ios/CmuxRemote/Keyboard/KeyButton.swift`

- [ ] **Step 1: Implement**

```swift
import UIKit

public final class KeyButton: UIControl {
    public let descriptor: KeyDescriptor
    public var onTap: (() -> Void)?
    public var isToggleOn: Bool = false { didSet { setNeedsLayout() } }
    private let label = UILabel()
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    public init(descriptor: KeyDescriptor) {
        self.descriptor = descriptor
        super.init(frame: .zero)
        backgroundColor = .systemGray5
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .label
        label.textAlignment = .center
        label.text = descriptor.label
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTarget(self, action: #selector(tap), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { nil }

    public override func layoutSubviews() {
        super.layoutSubviews()
        backgroundColor = isToggleOn ? .systemBlue.withAlphaComponent(0.4) : .systemGray5
    }

    @objc private func tap() {
        haptic.impactOccurred()
        onTap?()
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/CmuxRemote/Keyboard/KeyButton.swift
git commit -m "M5.3: KeyButton (haptic + toggle render)"
```

---

## Task 4 — `AccessoryBar` UIInputView

Hosts the three sections + a `UIScrollView` for the middle. Keeps a single set of active modifiers; emits `KeyAction` to a delegate.

**Files:**
- Create: `ios/CmuxRemote/Keyboard/AccessoryBar.swift`

- [ ] **Step 1: Implement**

```swift
import UIKit
import SharedKit

public protocol AccessoryBarDelegate: AnyObject {
    func accessoryBar(_ bar: AccessoryBar, didProduceKey key: Key)
    func accessoryBar(_ bar: AccessoryBar, didProduceText text: String)
    func accessoryBarRequestsDismiss(_ bar: AccessoryBar)
}

public final class AccessoryBar: UIInputView {
    public weak var delegate: AccessoryBarDelegate?
    public private(set) var traits: KeyTraits = .default
    public private(set) var layout: KBLayout
    private var activeModifiers: Set<KeyModifier> = []

    private let leftStack = UIStackView()
    private let middleScroll = UIScrollView()
    private let middleStack = UIStackView()
    private let rightStack = UIStackView()

    public init(layout: KBLayout) {
        self.layout = layout
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 48), inputViewStyle: .keyboard)
        backgroundColor = .clear
        configureStacks()
        rebuild()
    }
    required init?(coder: NSCoder) { nil }

    public func update(layout: KBLayout, traits: KeyTraits) {
        self.layout = layout; self.traits = traits
        rebuild()
    }

    private func configureStacks() {
        for stack in [leftStack, middleStack, rightStack] {
            stack.axis = .horizontal; stack.spacing = 6; stack.alignment = .center
        }
        middleScroll.translatesAutoresizingMaskIntoConstraints = false
        middleScroll.showsHorizontalScrollIndicator = false
        middleStack.translatesAutoresizingMaskIntoConstraints = false
        middleScroll.addSubview(middleStack)
        let outer = UIStackView(arrangedSubviews: [leftStack, middleScroll, rightStack])
        outer.axis = .horizontal; outer.spacing = 8; outer.alignment = .center
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            outer.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            middleStack.leadingAnchor.constraint(equalTo: middleScroll.leadingAnchor),
            middleStack.trailingAnchor.constraint(equalTo: middleScroll.trailingAnchor),
            middleStack.topAnchor.constraint(equalTo: middleScroll.topAnchor),
            middleStack.bottomAnchor.constraint(equalTo: middleScroll.bottomAnchor),
            middleStack.heightAnchor.constraint(equalTo: middleScroll.heightAnchor),
        ])
    }

    private func rebuild() {
        for v in leftStack.arrangedSubviews   { v.removeFromSuperview() }
        for v in middleStack.arrangedSubviews { v.removeFromSuperview() }
        for v in rightStack.arrangedSubviews  { v.removeFromSuperview() }
        for d in layout.left   { leftStack.addArrangedSubview(view(for: d)) }
        for d in layout.middle { middleStack.addArrangedSubview(view(for: d)) }
        for d in layout.right  { rightStack.addArrangedSubview(view(for: d)) }
    }

    private func view(for d: KeyDescriptor) -> UIView {
        switch d.kind {
        case .arrows:
            let v = ArrowsKeyView(descriptor: d)
            v.onDirection = { [weak self] dir in
                guard let self else { return }
                let key: Key
                switch dir {
                case .up: key = .up; case .down: key = .down
                case .left: key = .left; case .right: key = .right
                }
                self.delegate?.accessoryBar(self, didProduceKey: self.applyModifiers(to: key))
            }
            v.widthAnchor.constraint(equalToConstant: d.width).isActive = true
            return v
        case .dismissKeyboard:
            let b = KeyButton(descriptor: d)
            b.onTap = { [weak self] in self.flatMap { $0.delegate?.accessoryBarRequestsDismiss($0) } }
            b.widthAnchor.constraint(equalToConstant: d.width).isActive = true
            return b
        default:
            let b = KeyButton(descriptor: d)
            b.widthAnchor.constraint(equalToConstant: d.width).isActive = true
            b.onTap = { [weak self, weak b] in self?.handleTap(d, button: b) }
            return b
        }
    }

    private func handleTap(_ d: KeyDescriptor, button: KeyButton?) {
        switch d.kind {
        case .key(let k):
            delegate?.accessoryBar(self, didProduceKey: applyModifiers(to: k))
            activeModifiers.removeAll(); refreshModifierStates()
        case .modifier(let m):
            if activeModifiers.contains(m) { activeModifiers.remove(m) }
            else { activeModifiers.insert(m) }
            button?.isToggleOn = activeModifiers.contains(m)
            refreshModifierStates()
        case .symbol(let s):
            if activeModifiers.isEmpty { delegate?.accessoryBar(self, didProduceText: s) }
            else { delegate?.accessoryBar(self,
                                          didProduceKey: .named(s, modifiers: activeModifiers))
                   activeModifiers.removeAll(); refreshModifierStates() }
        case .snippet(_, let text):
            delegate?.accessoryBar(self, didProduceText: text)
        case .arrows, .dismissKeyboard: break
        }
    }

    private func applyModifiers(to key: Key) -> Key {
        guard !activeModifiers.isEmpty else { return key }
        return .named(KeyEncoder.encode(key), modifiers: activeModifiers)
    }

    private func refreshModifierStates() {
        for v in leftStack.arrangedSubviews + middleStack.arrangedSubviews + rightStack.arrangedSubviews {
            guard let btn = v as? KeyButton else { continue }
            if case .modifier(let m) = btn.descriptor.kind {
                btn.isToggleOn = activeModifiers.contains(m)
            }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/CmuxRemote/Keyboard/AccessoryBar.swift
git commit -m "M5.4: AccessoryBar (UIInputView, modifier toggling)"
```

---

## Task 5 — SwiftUI bridge

**Files:**
- Create: `ios/CmuxRemote/Keyboard/AccessoryBarBridge.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import UIKit
import SharedKit

public struct AccessoryBarBridge: UIViewRepresentable {
    let layout: KBLayout
    let onKey: (Key) -> Void
    let onText: (String) -> Void

    public func makeCoordinator() -> Coordinator {
        Coordinator(onKey: onKey, onText: onText)
    }

    public func makeUIView(context: Context) -> HostFieldView {
        let v = HostFieldView(layout: layout, delegate: context.coordinator)
        return v
    }

    public func updateUIView(_ uiView: HostFieldView, context: Context) {
        uiView.update(layout: layout)
    }

    public final class Coordinator: NSObject, AccessoryBarDelegate {
        let onKey: (Key) -> Void
        let onText: (String) -> Void
        init(onKey: @escaping (Key) -> Void, onText: @escaping (String) -> Void) {
            self.onKey = onKey; self.onText = onText
        }
        public func accessoryBar(_ bar: AccessoryBar, didProduceKey key: Key) { onKey(key) }
        public func accessoryBar(_ bar: AccessoryBar, didProduceText text: String) { onText(text) }
        public func accessoryBarRequestsDismiss(_ bar: AccessoryBar) {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        }
    }

    /// Hosts the hidden `UITextField` whose `inputAccessoryView` is the AccessoryBar.
    public final class HostFieldView: UIView, UITextFieldDelegate {
        private let field = UITextField()
        private var bar: AccessoryBar
        public init(layout: KBLayout, delegate: AccessoryBarDelegate) {
            self.bar = AccessoryBar(layout: layout)
            super.init(frame: .zero)
            self.bar.delegate = delegate
            field.delegate = self
            field.alpha = 0.01      // present but invisible
            field.inputAccessoryView = bar
            addSubview(field)
            field.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                field.topAnchor.constraint(equalTo: topAnchor),
                field.leadingAnchor.constraint(equalTo: leadingAnchor),
                field.widthAnchor.constraint(equalToConstant: 1),
                field.heightAnchor.constraint(equalToConstant: 1),
            ])
            DispatchQueue.main.async { self.field.becomeFirstResponder() }
        }
        required init?(coder: NSCoder) { nil }
        public func update(layout: KBLayout) { bar.update(layout: layout, traits: .default) }
    }
}
```

- [ ] **Step 2: Wire into `WorkspaceView` (modify M4 file)**

Add at the bottom of `WorkspaceView.body`'s VStack:

```swift
                AccessoryBarBridge(
                    layout: KBLayout.v10(snippets: snippets),
                    onKey:  { key in
                        Task { await surfaceStore.sendKey(workspaceId: ws.id,
                                                          surfaceId: activeSurfaceId ?? "",
                                                          key: key) }
                    },
                    onText: { text in
                        Task { await surfaceStore.sendText(workspaceId: ws.id,
                                                           surfaceId: activeSurfaceId ?? "",
                                                           text: text) }
                    }
                )
                .frame(height: 48)
```

`snippets` resolves via `@State private var snippets: [RelayConfigSnippet] = []` populated in `.task` from the `/v1/state` HTTP endpoint.

- [ ] **Step 3: Commit**

```bash
git add ios/CmuxRemote/Keyboard/AccessoryBarBridge.swift ios/CmuxRemote/Workspace/WorkspaceView.swift
git commit -m "M5.5: SwiftUI bridge + WorkspaceView wiring"
```

---

## Task 6 — `ArrowsKeyView` (press-and-drag with auto-repeat)

Spec section 9.2.

**Files:**
- Create: `ios/CmuxRemote/Keyboard/ArrowsKeyView.swift`
- Test:   `ios/CmuxRemoteUITests/ArrowsKeyViewUITests.swift`

- [ ] **Step 1: Implement**

```swift
import UIKit

public enum ArrowDirection { case up, down, left, right }

public final class ArrowsKeyView: UIControl {
    public let descriptor: KeyDescriptor
    public var onDirection: ((ArrowDirection) -> Void)?

    private var firstLocation: CGPoint?
    private var current: ArrowDirection?
    private var holdTimer: Timer?
    private var repeatTimer: Timer?
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let chevrons = [UILabel(), UILabel(), UILabel(), UILabel()]   // ↑ ↓ ← →

    public init(descriptor: KeyDescriptor) {
        self.descriptor = descriptor
        super.init(frame: .zero)
        backgroundColor = .systemGray5
        layer.cornerRadius = 6; layer.cornerCurve = .continuous
        let glyphs = ["▲","▼","◀","▶"]
        for (i, l) in chevrons.enumerated() {
            l.text = glyphs[i]; l.textAlignment = .center
            l.font = .systemFont(ofSize: 10, weight: .semibold)
            l.translatesAutoresizingMaskIntoConstraints = false
            addSubview(l)
        }
        // up center-top, down center-bottom, left mid-left, right mid-right
        NSLayoutConstraint.activate([
            chevrons[0].centerXAnchor.constraint(equalTo: centerXAnchor),
            chevrons[0].topAnchor.constraint(equalTo: topAnchor, constant: 2),
            chevrons[1].centerXAnchor.constraint(equalTo: centerXAnchor),
            chevrons[1].bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            chevrons[2].centerYAnchor.constraint(equalTo: centerYAnchor),
            chevrons[2].leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            chevrons[3].centerYAnchor.constraint(equalTo: centerYAnchor),
            chevrons[3].trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
        isMultipleTouchEnabled = false
    }
    required init?(coder: NSCoder) { nil }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        firstLocation = t.location(in: self)
        current = nil
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let origin = firstLocation else { return }
        let pt = t.location(in: self)
        let dx = pt.x - origin.x, dy = pt.y - origin.y
        let dir: ArrowDirection
        if abs(dx) > abs(dy) { dir = dx >= 0 ? .right : .left }
        else                  { dir = dy >= 0 ? .down  : .up }
        guard dir != current else { return }
        current = dir
        haptic.impactOccurred()
        onDirection?(dir)
        scheduleAutoRepeat()
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouch()
    }
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouch()
    }
    private func endTouch() {
        firstLocation = nil; current = nil
        holdTimer?.invalidate(); holdTimer = nil
        repeatTimer?.invalidate(); repeatTimer = nil
    }

    private func scheduleAutoRepeat() {
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let dir = self.current else { return }
                self.haptic.impactOccurred()
                self.onDirection?(dir)
            }
        }
    }
}
```

- [ ] **Step 2: UI test**

```swift
import XCTest

final class ArrowsKeyViewUITests: XCTestCase {
    func testDragRightThenLeftEmits() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launch()
        // The fake relay path connects automatically; navigate to Active tab.
        app.tabBars.buttons["Active"].tap()
        // ArrowsKeyView is identified by accessibilityIdentifier "arrows".
        let arrows = app.otherElements["arrows"]
        XCTAssertTrue(arrows.waitForExistence(timeout: 5))
        arrows.press(forDuration: 0.6, thenDragTo: arrows)
        // The fake relay should record at least one .right key — assert via a debug
        // banner the fake bootstrap exposes.
        XCTAssertTrue(app.staticTexts["dbg.last_key.up"].exists ||
                      app.staticTexts["dbg.last_key.down"].exists ||
                      app.staticTexts["dbg.last_key.left"].exists ||
                      app.staticTexts["dbg.last_key.right"].exists)
    }
}
```

To make the assertion possible, the fake-relay bootstrap (added in M4 task 18) exposes a `Text("dbg.last_key.\(KeyEncoder.encode(lastKey))")` overlay when `CMUX_FAKE_RELAY=1`. Add `accessibilityIdentifier("arrows")` to `ArrowsKeyView.init` (`accessibilityIdentifier = "arrows"`).

- [ ] **Step 3: Commit (Blink pattern adapted)**

```bash
git add ios/CmuxRemote/Keyboard/ArrowsKeyView.swift ios/CmuxRemoteUITests/ArrowsKeyViewUITests.swift
git commit -m "M5.6: ArrowsKeyView press-and-drag + auto-repeat (pattern adapted from Blink Shell, GPLv3)"
```

---

## Task 7 — `CommandHUDView` (hardware-keyboard shortcuts)

Spec section 9.3. `cmd+1…9` selects workspace by index; `cmd+[` / `cmd+]` cycles surfaces.

**Files:**
- Create: `ios/CmuxRemote/Keyboard/CommandHUDView.swift`

- [ ] **Step 1: Implement**

```swift
import UIKit
import SwiftUI

public final class CommandHUDController: UIViewController {
    public var onWorkspaceIndex: ((Int) -> Void)?
    public var onCycleSurface: ((Int) -> Void)?     // -1 / +1

    public override var canBecomeFirstResponder: Bool { true }

    public override var keyCommands: [UIKeyCommand]? {
        var cmds: [UIKeyCommand] = []
        for i in 1...9 {
            cmds.append(UIKeyCommand(title: "Workspace \(i)",
                                     action: #selector(workspaceShortcut(_:)),
                                     input: "\(i)", modifierFlags: .command))
        }
        cmds.append(UIKeyCommand(title: "Prev surface",
                                 action: #selector(prevSurface),
                                 input: "[", modifierFlags: .command))
        cmds.append(UIKeyCommand(title: "Next surface",
                                 action: #selector(nextSurface),
                                 input: "]", modifierFlags: .command))
        return cmds
    }

    @objc private func workspaceShortcut(_ sender: UIKeyCommand) {
        guard let s = sender.input, let n = Int(s) else { return }
        onWorkspaceIndex?(n)
    }
    @objc private func prevSurface() { onCycleSurface?(-1) }
    @objc private func nextSurface() { onCycleSurface?(+1) }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); becomeFirstResponder()
    }
}

public struct CommandHUDViewBridge: UIViewControllerRepresentable {
    let onWorkspaceIndex: (Int) -> Void
    let onCycleSurface: (Int) -> Void
    public func makeUIViewController(context: Context) -> CommandHUDController {
        let c = CommandHUDController()
        c.onWorkspaceIndex = onWorkspaceIndex
        c.onCycleSurface = onCycleSurface
        return c
    }
    public func updateUIViewController(_ uiViewController: CommandHUDController, context: Context) {}
}
```

- [ ] **Step 2: Wire into `ContentView`**

Add as a sibling of the TabView, sized to .frame(width: 0, height: 0):

```swift
ZStack {
    TabView { /* ... */ }
    CommandHUDViewBridge(
        onWorkspaceIndex: { idx in
            guard idx > 0, idx <= ws.workspaces.count else { return }
            ws.selectedId = ws.workspaces[idx - 1].id
        },
        onCycleSurface: { delta in /* cycle logic */ }
    ).frame(width: 0, height: 0)
}
```

- [ ] **Step 3: Commit (Blink pattern adapted)**

```bash
git add ios/CmuxRemote/Keyboard/CommandHUDView.swift ios/CmuxRemote/ContentView.swift
git commit -m "M5.7: CommandHUDView (cmd+1..9, cmd+[, cmd+]) — pattern adapted from Blink Shell, GPLv3"
```

---

## Task 8 — Snippet hydration from `/v1/state`

**Files:**
- Create: `ios/CmuxRemote/Keyboard/Snippets.swift`
- Test:   `ios/CmuxRemoteTests/SnippetsTests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest
@testable import CmuxRemote

final class SnippetsTests: XCTestCase {
    func testParseStateResponse() throws {
        let raw = #"{"snippets":[{"label":"ll","text":"ls -alh\n"}],"defaultFps":15}"#
        let s = try Snippets.parse(stateJSON: Data(raw.utf8))
        XCTAssertEqual(s.first?.label, "ll")
        XCTAssertEqual(s.first?.text, "ls -alh\n")
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public enum Snippets {
    public struct State: Decodable {
        public struct Snippet: Decodable { public let label: String; public let text: String }
        public let snippets: [Snippet]
    }
    public static func parse(stateJSON data: Data) throws -> [RelayConfigSnippet] {
        let s = try JSONDecoder().decode(State.self, from: data)
        return s.snippets.map { .init(label: $0.label, text: $0.text) }
    }

    public static func fetch(host: String, port: Int, bearer: String,
                             http: HTTPClientFacade) async throws -> [RelayConfigSnippet]
    {
        var req = URLRequest(url: URL(string: "https://\(host):\(port)/v1/state")!)
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, code) = try await http.request(req)
        guard code == 200 else { return [] }
        return try parse(stateJSON: data)
    }
}
```

- [ ] **Step 3: Wire into `WorkspaceView` `.task`**

```swift
.task {
    let kc = Keychain(service: "com.genie.cmuxremote")
    let host = UserDefaults.standard.string(forKey: "cmux.host") ?? ""
    let port = UserDefaults.standard.integer(forKey: "cmux.port") == 0
                ? 4399 : UserDefaults.standard.integer(forKey: "cmux.port")
    if let bearer = try? kc.get("bearer"), !host.isEmpty {
        snippets = (try? await Snippets.fetch(host: host, port: port,
                                              bearer: bearer, http: URLSessionHTTP())) ?? []
    }
}
```

- [ ] **Step 4: Run + commit**

```bash
xcodebuild test -project ios/CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:CmuxRemoteTests/SnippetsTests | tail -3
git add ios/CmuxRemote/Keyboard/Snippets.swift ios/CmuxRemote/Workspace/WorkspaceView.swift ios/CmuxRemoteTests/SnippetsTests.swift
git commit -m "M5.8: snippet hydration from /v1/state"
```

---

## Task 9 — XCUITest: tap each AccessoryBar key

**Files:**
- Create: `ios/CmuxRemoteUITests/AccessoryBarUITests.swift`

- [ ] **Step 1: Test**

```swift
import XCTest

final class AccessoryBarUITests: XCTestCase {
    func testEachLeftKeyEmits() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launch()
        app.tabBars.buttons["Active"].tap()
        for label in ["esc", "ctrl", "alt", "tab"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 3),
                          "missing key \(label)")
            app.buttons[label].tap()
        }
        XCTAssertTrue(app.staticTexts.matching(identifier: "dbg.last_key").firstMatch
                      .waitForExistence(timeout: 2))
    }
}
```

- [ ] **Step 2: Add `accessibilityIdentifier` on each `KeyButton`**

In `KeyButton.init`, after creating `label`:

```swift
self.accessibilityLabel = descriptor.label
self.accessibilityIdentifier = descriptor.label
```

- [ ] **Step 3: Run + commit**

```bash
xcodebuild test -project ios/CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:CmuxRemoteUITests/AccessoryBarUITests | tail -3
git add ios/CmuxRemoteUITests/AccessoryBarUITests.swift ios/CmuxRemote/Keyboard/KeyButton.swift
git commit -m "M5.9: AccessoryBar XCUITest — each left key emits"
```

---

## Task 10 — Manual smoke (vim insert + cursor traversal)

Manual: with M3 relay running and M4 wiring intact, on the simulator:

1. Open a workspace, select a shell surface
2. Type `vim` + enter via system keyboard
3. Tap `i` (system keyboard) to enter insert mode — verify the surface shows `-- INSERT --`
4. Tap `esc` (AccessoryBar left section) — surface returns to normal mode
5. Tap-drag the ArrowsKey diagonally up-right — cursor moves up then right with auto-repeat
6. Tap a snippet (e.g. `ll`) — surface receives `ls -alh\n`
7. With a paired BT keyboard, hit `cmd+]` — surface tab strip cycles to next surface

Document successful smoke in the merge commit body.

## Exit criteria

```bash
xcodebuild test -project ios/CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination 'platform=iOS Simulator,name=iPhone 15' | tail -10
```

Required:
- All `CmuxRemoteTests` (incl. `KeyTraitsTests`, `KBLayoutTests`, `SnippetsTests`) pass
- All `CmuxRemoteUITests` (incl. `ArrowsKeyViewUITests`, `AccessoryBarUITests`) pass
- Manual smoke list above is fully green

## Self-review

- [ ] **Coverage:** AccessoryBar lays out left/middle/right per spec section 9.2; ArrowsKeyView gesture machinery + 0.5 s hold + 0.1 s repeat per spec; CommandHUD listens for cmd+1..9 / cmd+[ / cmd+] per spec section 9.3.
- [ ] **Placeholder scan:** `grep -RnE "TODO|FIXME|tbd" ios/CmuxRemote/Keyboard` returns no hits.
- [ ] **Type consistency:** `Key`/`KeyEncoder` from SharedKit drives every emission. AccessoryBar uses `KeyTraits` not a duplicate enum.
- [ ] **License:** every commit using a Blink-pattern adaptation says so in the message.

## Merge

```bash
git checkout main
git merge --ff-only m5-keyboard
git branch -d m5-keyboard
```

Pick up M6 next: `2026-05-09-m6-apns.md`.
