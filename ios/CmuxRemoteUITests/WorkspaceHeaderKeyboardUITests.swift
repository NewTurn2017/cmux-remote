import XCTest

final class WorkspaceHeaderKeyboardUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSurfaceChipsStayVisibleAndHeaderNeverCoversContentAcrossInputStates() throws {
        let app = launchTabTypesWorkspace()
        let viewport = app.scrollViews["TerminalViewport"]
        let card = app.descendants(matching: .any)["NonTerminalSurfaceCard"]
        let keyboard = app.keyboards.firstMatch
        let commandField = app.textFields["CommandComposerField"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), app.debugDescription)

        assertHeaderLayout(in: app, state: "keyboard hidden", keyboardVisible: false)
        assertViewportBelowHeader(viewport, in: app, state: "keyboard hidden")

        XCTAssertTrue(commandField.waitForExistence(timeout: 5), app.debugDescription)
        commandField.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Software keyboard must be visible")
        assertHeaderLayout(in: app, state: "command field + keyboard", keyboardVisible: true)
        assertViewportBelowHeader(viewport, in: app, state: "command field + keyboard")
        retainScreenshot(named: "header-command-keyboard")

        chip("README.md", in: app).tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
        if !keyboard.exists {
            commandField.tap()
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Software keyboard must be visible")
        }
        assertHeaderLayout(in: app, state: "markdown surface + keyboard", keyboardVisible: true)
        retainScreenshot(named: "header-markdown-keyboard")

        chip("claude-code", in: app).tap()
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), app.debugDescription)

        app.buttons["InputModeToggleButton"].tap()
        XCTAssertTrue(app.textViews["LiveInputField"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Live input must keep the software keyboard visible")
        assertHeaderLayout(in: app, state: "live input + keyboard", keyboardVisible: true)
        assertViewportBelowHeader(viewport, in: app, state: "live input + keyboard")
        retainScreenshot(named: "header-live-keyboard")

        app.buttons["CommandKeyboardDismissButton"].tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "Dismiss must hide the software keyboard")
        assertHeaderLayout(in: app, state: "keyboard dismissed", keyboardVisible: false)
        assertViewportBelowHeader(viewport, in: app, state: "keyboard dismissed")
    }

    private func assertHeaderLayout(in app: XCUIApplication, state: String, keyboardVisible: Bool) {
        let header = app.descendants(matching: .any)["WorkspaceHeader"]
        let chipBar = app.descendants(matching: .any)["SurfaceChipBar"]
        let contentTop = app.descendants(matching: .any)["WorkspaceContentTopEdge"]
        let firstChip = app.buttons.matching(identifier: "SurfaceChip-terminal").firstMatch
        for element in [header, chipBar, contentTop, firstChip] {
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(state): missing \(element)\n\(app.debugDescription)")
        }
        XCTAssertTrue(firstChip.isHittable, "\(state): surface chip must be tappable")
        XCTAssertLessThanOrEqual(chipBar.frame.maxY, header.frame.maxY + 1, "\(state): chip bar must sit inside the header")
        waitUntil("\(state): content top edge must start below the header", in: app) {
            contentTop.frame.minY >= header.frame.maxY - 1
        }
        if keyboardVisible {
            let keyboard = app.keyboards.firstMatch
            XCTAssertLessThanOrEqual(chipBar.frame.maxY, keyboard.frame.minY, "\(state): chip bar must stay above the keyboard")
        }
    }

    private func assertViewportBelowHeader(_ viewport: XCUIElement, in app: XCUIApplication, state: String) {
        let header = app.descendants(matching: .any)["WorkspaceHeader"]
        waitUntil("\(state): first terminal row must start below the header", in: app) {
            viewport.exists && viewport.frame.minY >= header.frame.maxY - 1
        }
    }

    private func waitUntil(_ message: String, in app: XCUIApplication, condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, "\(message)\n\(app.debugDescription)")
    }

    private func launchTabTypesWorkspace() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launchEnvironment["CMUX_SKIP_SPLASH"] = "1"
        app.launchArguments += [
            "--cmux-skip-splash",
            "-cmux.demoMode", "NO",
            "-cmux.localNotificationsEnabled", "NO",
        ]
        addTeardownBlock { app.terminate() }
        app.launch()

        let card = app.buttons["WorkspaceCard-WS-DEMO-TABS"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
        let tabBar = app.buttons["Settings"]
        var swipes = 0
        while swipes < 8, !(card.isHittable && card.frame.maxY < tabBar.frame.minY - 16) {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(card.isHittable, app.debugDescription)
        card.tap()
        XCTAssertTrue(app.buttons["localhost:3000"].waitForExistence(timeout: 5), app.debugDescription)
        return app
    }

    private func chip(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.buttons[title]
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        return element
    }

    private func retainScreenshot(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
