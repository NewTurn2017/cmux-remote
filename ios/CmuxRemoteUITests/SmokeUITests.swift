import XCTest

final class SmokeUITests: XCTestCase {
    func testTabsExistAfterConnect() throws {
        let app = launchFakeRelayApp()
        XCTAssertTrue(app.buttons["Workspaces"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Active"].exists)
        XCTAssertTrue(app.buttons["Inbox"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
    }

    func testCommandComposerDispatchesInputThroughFakeRelay() throws {
        let app = launchFakeRelayApp()

        let workspace = app.buttons["Demo Workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()

        let commandField = app.textFields["CommandComposerField"]
        XCTAssertTrue(commandField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["TerminalScrollToBottomButton"].exists)
        commandField.tap()
        commandField.typeText("pwd")
        let submitButton = app.buttons["CommandSubmitButton"]
        if !submitButton.waitForHittable(timeout: 5) {
            print(app.debugDescription)
        }
        XCTAssertTrue(submitButton.isHittable)
        submitButton.tap()

        let inputStatus = app.staticTexts["InputStatusMessage"]
        XCTAssertTrue(inputStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(inputStatus.label.contains("Sent pwd"), inputStatus.label)

        app.buttons["esc"].tap()
        XCTAssertTrue(inputStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(inputStatus.label.contains("Sent esc"), inputStatus.label)

        app.buttons["send up arrow"].tap()
        XCTAssertTrue(inputStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(inputStatus.label.contains("Sent up"), inputStatus.label)

        app.buttons["send down arrow"].tap()
        XCTAssertTrue(inputStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(inputStatus.label.contains("Sent down"), inputStatus.label)

        app.buttons["send enter"].tap()
        XCTAssertTrue(inputStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(inputStatus.label.contains("Sent enter"), inputStatus.label)
    }

    func testSurfaceChipBarCreatesAndClosesSurfaces() throws {
        let app = launchFakeRelayApp()

        let workspace = app.buttons["Demo Workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
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

        let workspace = app.buttons["Demo Workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()

        let viewport = app.scrollViews["TerminalViewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        XCTAssertTrue(viewport.valueDescription.contains("hello from fake relay"), viewport.valueDescription)

        let commandField = app.textFields["CommandComposerField"]
        XCTAssertTrue(commandField.waitForExistence(timeout: 5))
        commandField.tap()

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Software keyboard must be visible for keyboard-overlap regression coverage")
        commandField.typeText("x")
        let keyboardTop = keyboard.frame.minY

        assertAboveKeyboard(commandField, keyboardTop: keyboardTop, name: "command field")
        assertAboveKeyboard(app.buttons["CommandKeyboardDismissButton"], keyboardTop: keyboardTop, name: "keyboard dismiss")
        assertAboveKeyboard(app.buttons["CommandBackspaceButton"], keyboardTop: keyboardTop, name: "backspace")
        assertAboveKeyboard(app.buttons["CommandSubmitButton"], keyboardTop: keyboardTop, name: "send")
        let escShortcut = app.buttons["esc"]
        assertVisibleAboveKeyboard(escShortcut, keyboardTop: keyboardTop, name: "esc shortcut")
        assertVisibleAboveKeyboard(app.buttons["shift enter line break"], keyboardTop: keyboardTop, name: "line break shortcut")

        XCTAssertGreaterThan(viewport.frame.height, 30, "Terminal viewport should keep usable vertical space above the composer")
        XCTAssertGreaterThan(commandField.frame.minY, 240, "Terminal viewport should keep visible vertical space above the composer")

        app.buttons["TerminalScrollToBottomButton"].tap()
        XCTAssertTrue(keyboard.exists, "Scroll-to-bottom must not steal focus or toggle the software keyboard")
    }

    private func launchFakeRelayApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launchEnvironment["CMUX_SKIP_SPLASH"] = "1"
        app.launchArguments.append("--cmux-skip-splash")
        app.launch()
        return app
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
