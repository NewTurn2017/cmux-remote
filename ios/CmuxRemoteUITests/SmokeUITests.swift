import XCTest
import UIKit

final class SmokeUITests: XCTestCase {
    func testIPadLandscapeUsesCompactAccessoryPanel() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPad-only layout assertion")
        }
        addTeardownBlock {
            XCUIDevice.shared.orientation = .portrait
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchFakeRelayApp()

        let workspace = primaryWorkspaceButton(in: app)
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()

        let accessory = app.otherElements["TerminalAccessoryPanel"]
        XCTAssertTrue(accessory.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            accessory.frame.height,
            app.frame.height * 0.15 + 2,
            "The iPad command deck should leave at least 85% of landscape height to the terminal shell"
        )
        XCTAssertGreaterThan(
            app.scrollViews["TerminalViewport"].frame.width,
            app.frame.width * 0.9,
            "The terminal should use the native iPad window width"
        )
        let commandField = app.textFields["CommandComposerField"]
        XCTAssertTrue(commandField.exists)
        XCTAssertTrue(commandField.isHittable, "CommandComposerField should remain hittable")
        XCTAssertGreaterThanOrEqual(commandField.frame.height, 44)
        XCTAssertGreaterThanOrEqual(commandField.frame.width, 44)

        for identifier in [
            "InputModeToggleButton",
            "CommandKeyboardDismissButton",
            "CommandBackspaceButton",
            "CommandPasteButton",
            "CommandPhotoAttachButton",
            "CommandSubmitButton",
            "esc",
            "send ctrl c",
            "send slash new shortcut",
            "send space for omx selection",
        ] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.isHittable, "\(identifier) should remain hittable")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, "\(identifier) should meet the iPad touch target")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, "\(identifier) should meet the iPad touch target")
        }

        commandField.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        commandField.typeText("pwd\n")

        let inputStatus = app.staticTexts["InputStatusMessage"]
        XCTAssertTrue(inputStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(inputStatus.label.contains("Sent pwd"), inputStatus.label)
        XCTAssertGreaterThanOrEqual(app.buttons["esc"].frame.width, 44)
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 3))

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iPad compact terminal accessory"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testOpaqueBlackTerminalViewportVisualContract() throws {
        if UIDevice.current.userInterfaceIdiom == .pad {
            addTeardownBlock {
                XCUIDevice.shared.orientation = .portrait
            }
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let app = launchFakeRelayApp()

        let workspace = primaryWorkspaceButton(in: app)
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()

        let viewport = app.scrollViews["TerminalViewport"]
        let background = app.otherElements["TerminalCanvasBackground"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(background.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(background.value as? String, "opaque-black")

        let submit = app.buttons["CommandSubmitButton"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThanOrEqual(submit.frame.width, 46, app.debugDescription)
        XCTAssertLessThanOrEqual(submit.frame.height, 46, app.debugDescription)
        recordScreenshot(named: UIDevice.current.userInterfaceIdiom == .pad
            ? "opaque-black-terminal-ipad-m5"
            : "opaque-black-terminal-iphone-17-pro")
    }

    func testIPadAppStoreScreenshots() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPad-only App Store screenshots")
        }
        addTeardownBlock {
            XCUIDevice.shared.orientation = .portrait
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchFakeRelayApp()

        XCTAssertTrue(app.buttons["Workspaces"].waitForExistence(timeout: 5))
        recordScreenshot(named: "02-ipad-workspaces")

        let workspace = primaryWorkspaceButton(in: app)
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()
        XCTAssertTrue(app.scrollViews["TerminalViewport"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["TerminalAccessoryPanel"].waitForExistence(timeout: 5))
        recordScreenshot(named: "01-ipad-terminal")

        let backButton = app.buttons["WorkspaceBackButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()
        let settingsTab = app.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
        XCTAssertTrue(app.staticTexts["settings"].waitForExistence(timeout: 5))
        recordScreenshot(named: "03-ipad-settings")
    }

    func testTabsExistAfterConnect() throws {
        let app = launchFakeRelayApp()
        XCTAssertTrue(app.buttons["Workspaces"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Active"].exists)
        XCTAssertTrue(app.buttons["Inbox"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
    }

    func testCommandComposerDispatchesInputThroughFakeRelay() throws {
        let app = launchFakeRelayApp()

        let workspace = primaryWorkspaceButton(in: app)
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()

        let commandField = app.textFields["CommandComposerField"]
        XCTAssertTrue(commandField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["TerminalScrollToBottomButton"].exists)
        commandField.tap()

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Software keyboard should open while composing a command")

        commandField.typeText("pwd")
        let submitButton = app.buttons["CommandSubmitButton"]
        if !submitButton.waitForHittable(timeout: 5) {
            print(app.debugDescription)
        }
        XCTAssertTrue(submitButton.isHittable)
        submitButton.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 3), "Keyboard should close automatically after ENTER submits a command")

        let inputStatus = app.staticTexts["InputStatusMessage"]
        XCTAssertTrue(inputStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(inputStatus.label.contains("Sent pwd"), inputStatus.label)

        app.buttons["esc"].tap()
        XCTAssertTrue(inputStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(inputStatus.label.contains("Sent esc"), inputStatus.label)

        app.buttons["send ctrl c"].tap()
        XCTAssertTrue(inputStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(inputStatus.label.contains("Sent ctrl+c"), inputStatus.label)

        app.buttons["send up arrow"].tap()
        XCTAssertTrue(inputStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(inputStatus.label.contains("Sent up"), inputStatus.label)

        app.buttons["send down arrow"].tap()
        XCTAssertTrue(inputStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(inputStatus.label.contains("Sent down"), inputStatus.label)

        app.buttons["send slash new shortcut"].tap()
        XCTAssertTrue(inputStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(inputStatus.label.contains("Sent /new"), inputStatus.label)

        app.buttons["send space for omx selection"].tap()
        XCTAssertTrue(inputStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(inputStatus.label.contains("Sent text"), inputStatus.label)
    }

    func testSurfaceChipBarCreatesAndClosesSurfaces() throws {
        let app = launchFakeRelayApp()

        let workspace = app.buttons["Demo Workspace"]
        guard workspace.waitForExistence(timeout: 5) else {
            throw XCTSkip("Fake relay surface mutation fixture is unavailable; app is showing demo content")
        }
        workspace.tap()

        let newSurface = app.buttons["NewSurfaceButton"]
        XCTAssertTrue(newSurface.waitForExistence(timeout: 5))

        let originalChip = app.buttons["shell"]
        XCTAssertTrue(originalChip.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["Close surface shell"].exists,
            "Last remaining surface chip must not expose a close button"
        )

        newSurface.tap()
        let secondChip = app.buttons["shell 2"]
        XCTAssertTrue(secondChip.waitForExistence(timeout: 5))

        let closeOriginal = app.buttons["Close surface shell"]
        XCTAssertTrue(closeOriginal.waitForExistence(timeout: 5))
        closeOriginal.tap()

        let confirmButton = app.buttons["Close shell"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()

        let removed = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: removed, object: originalChip)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
        XCTAssertTrue(secondChip.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["Close surface shell 2"].exists,
            "Surface chip x must hide again once we're back to a single surface"
        )
    }

    func testKeyboardKeepsTerminalAndComposerControlsVisible() throws {
        let app = launchFakeRelayApp()

        let workspace = primaryWorkspaceButton(in: app)
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()

        let viewport = app.scrollViews["TerminalViewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        XCTAssertFalse(viewport.valueDescription.isEmpty, viewport.valueDescription)

        let commandField = app.textFields["CommandComposerField"]
        XCTAssertTrue(commandField.waitForExistence(timeout: 5))
        let idleScrollButton = app.buttons["TerminalScrollToBottomButton"]
        XCTAssertTrue(idleScrollButton.exists)
        let idleAccessory = app.otherElements["TerminalAccessoryPanel"]
        XCTAssertTrue(idleAccessory.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            app.frame.maxY - idleAccessory.frame.maxY,
            4,
            "Input accessory should sit flush with the bottom edge when the keyboard is hidden"
        )
        XCTAssertGreaterThan(
            viewport.frame.height,
            app.frame.height * 0.32,
            "Terminal viewport should not collapse into a large blank middle area before the keyboard appears"
        )
        commandField.tap()

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Software keyboard must be visible for keyboard-overlap regression coverage")
        commandField.typeText("x")
        let keyboardTop = keyboard.frame.minY
        assertAboveKeyboard(commandField, keyboardTop: keyboardTop, name: "command field")
        assertAboveKeyboard(app.buttons["CommandKeyboardDismissButton"], keyboardTop: keyboardTop, name: "keyboard dismiss")
        assertAboveKeyboard(app.buttons["CommandBackspaceButton"], keyboardTop: keyboardTop, name: "backspace")
        assertAboveKeyboard(app.buttons["CommandPasteButton"], keyboardTop: keyboardTop, name: "paste")
        assertAboveKeyboard(app.buttons["CommandPhotoAttachButton"], keyboardTop: keyboardTop, name: "photo attach")
        assertAboveKeyboard(app.buttons["CommandSubmitButton"], keyboardTop: keyboardTop, name: "send")
        let escShortcut = app.buttons["esc"]
        assertVisibleAboveKeyboard(escShortcut, keyboardTop: keyboardTop, name: "esc shortcut")
        assertVisibleAboveKeyboard(app.buttons["send ctrl c"], keyboardTop: keyboardTop, name: "ctrl+c shortcut")
        assertVisibleAboveKeyboard(app.buttons["send slash new shortcut"], keyboardTop: keyboardTop, name: "/new shortcut")
        assertVisibleAboveKeyboard(app.buttons["send space for omx selection"], keyboardTop: keyboardTop, name: "space shortcut")
        let scrollButton = app.buttons["TerminalScrollToBottomButton"]
        XCTAssertTrue(scrollButton.exists, "Scroll-to-bottom button should keep its pre-regression overlay behavior")

        XCTAssertGreaterThan(viewport.frame.height, 30, "Terminal viewport should keep usable vertical space above the composer")
        XCTAssertGreaterThan(commandField.frame.minY, 140, "Terminal viewport should keep visible vertical space above the composer")

        scrollButton.tap()
        XCTAssertTrue(keyboard.exists, "Scroll-to-bottom must not steal focus or toggle the software keyboard")
    }


    func testInboxShowsClaudeCodeNeedsInputFromWorkspaceStatus() throws {
        let app = launchFakeRelayApp()

        let inboxTab = app.buttons["Inbox"]
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 5))
        inboxTab.tap()

        let title = app.staticTexts["Claude Code needs input"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Claude is waiting for your input"].exists)
    }

    func testInboxUnreadBadgeClearsAfterOpeningInboxMessage() throws {
        let app = launchFakeRelayApp()

        let inboxBadge = app.staticTexts["InboxUnreadBadge"]
        XCTAssertTrue(inboxBadge.waitForExistence(timeout: 5), app.debugDescription)
        let initialCount = try unreadBadgeCount(in: app)

        app.buttons["Inbox"].tap()
        app.staticTexts["Claude Code needs input"].tap()

        let backButton = app.buttons["WorkspaceBackButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), app.debugDescription)
        backButton.tap()

        let finalCount = try unreadBadgeCount(in: app)
        XCTAssertLessThan(finalCount, initialCount)
    }

    func testLiveInputModeSendsCharactersWithoutSubmit() throws {
        let app = launchFakeRelayApp()

        let workspace = primaryWorkspaceButton(in: app)
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()

        let modeToggle = app.buttons["InputModeToggleButton"]
        XCTAssertTrue(modeToggle.waitForExistence(timeout: 5))
        modeToggle.tap()

        let liveTextView = app.textViews["LiveInputField"]
        let liveField = liveTextView.waitForExistence(timeout: 3)
            ? liveTextView
            : app.textFields["LiveInputField"]
        XCTAssertTrue(liveField.waitForExistence(timeout: 5))
        liveField.tap()
        liveField.typeText("a")

        XCTAssertTrue(liveField.valueDescription.contains("a"), liveField.valueDescription)

        let inputStatus = app.staticTexts["InputStatusMessage"]
        XCTAssertTrue(inputStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(inputStatus.label.contains("Sent a"), inputStatus.label)
    }

    private func launchFakeRelayApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launchEnvironment["CMUX_SKIP_SPLASH"] = "1"
        app.launchArguments.append("--cmux-skip-splash")
        app.launchArguments.append("-cmux.demoMode")
        app.launchArguments.append("NO")
        app.launchArguments.append("-cmux.localNotificationsEnabled")
        app.launchArguments.append("NO")
        app.launch()
        return app
    }

    private func recordScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func primaryWorkspaceButton(in app: XCUIApplication) -> XCUIElement {
        for name in ["Demo Workspace", "agent-lab"] {
            let button = app.buttons[name]
            if button.waitForExistence(timeout: 2) {
                return button
            }
        }
        return app.buttons["Demo Workspace"]
    }

    private func assertAboveKeyboard(_ element: XCUIElement, keyboardTop: CGFloat, name: String) {
        XCTAssertTrue(element.exists, "\(name) should exist")
        XCTAssertTrue(element.isHittable, "\(name) should be hittable above the software keyboard")
        XCTAssertLessThanOrEqual(element.frame.maxY, keyboardTop - 1, "\(name) should not overlap the software keyboard")
    }

    private func assertVisibleAboveKeyboard(_ element: XCUIElement, keyboardTop: CGFloat, name: String) {
        XCTAssertTrue(element.exists, "\(name) should exist")
        XCTAssertLessThanOrEqual(element.frame.maxY, keyboardTop - 1, "\(name) should not overlap the software keyboard")
    }

    private func unreadBadgeCount(in app: XCUIApplication) throws -> Int {
        let badge = app.staticTexts["InboxUnreadBadge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), app.debugDescription)
        let prefix = badge.label.split(separator: " ").first
        return try XCTUnwrap(prefix.flatMap { Int(String($0)) })
    }
}

private extension XCUIElement {
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    var valueDescription: String {
        if let value = self.value as? String {
            return value
        }
        return label
    }
}
