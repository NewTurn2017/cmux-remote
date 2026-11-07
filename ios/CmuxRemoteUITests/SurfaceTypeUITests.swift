import XCTest

final class SurfaceTypeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTabTypesChipsShowKindAndOpenOnFirstTerminal() throws {
        let app = launchTabTypesWorkspace()

        XCTAssertTrue(app.descendants(matching: .any)["TerminalViewport"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["NonTerminalSurfaceCard"].exists)

        XCTAssertEqual(chip("localhost:3000", in: app).identifier, "SurfaceChip-browser")
        XCTAssertEqual(chip("README.md", in: app).identifier, "SurfaceChip-markdown")
        XCTAssertEqual(chip("claude-code", in: app).identifier, "SurfaceChip-terminal")
        XCTAssertEqual(app.buttons.matching(identifier: "SurfaceChip-browser").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "SurfaceChip-markdown").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "SurfaceChip-terminal").count, 3)
    }

    func testNonTerminalTabsShowPlaceholderCard() throws {
        let app = launchTabTypesWorkspace()
        let viewport = app.descendants(matching: .any)["TerminalViewport"]
        let card = app.descendants(matching: .any)["NonTerminalSurfaceCard"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))

        chip("localhost:3000", in: app).tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.label.contains("localhost:3000"), card.label)
        XCTAssertFalse(viewport.exists)

        chip("README.md", in: app).tap()
        XCTAssertTrue(waitForLabel(of: card, containing: "README.md"), app.debugDescription)

        chip("claude-code", in: app).tap()
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
    }

    func testStaleListTabSwitchesToPlaceholderOnNotTerminalEvent() throws {
        let app = launchTabTypesWorkspace()
        XCTAssertTrue(app.descendants(matching: .any)["TerminalViewport"].waitForExistence(timeout: 5))

        chip("old-list tab", in: app).tap()

        let card = app.descendants(matching: .any)["NonTerminalSurfaceCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.label.contains("old-list tab"), card.label)
    }

    func testPullPastEdgesOnAlternateScreenSendsPageKeys() throws {
        let app = launchTabTypesWorkspace()
        let viewport = app.descendants(matching: .any)["TerminalViewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        let inputStatus = app.staticTexts["InputStatusMessage"]

        drag(viewport, from: 0.25, to: 0.98)
        XCTAssertTrue(waitForLabel(of: inputStatus, containing: "Sent page_up"), app.debugDescription)

        drag(viewport, from: 0.75, to: 0.02)
        XCTAssertTrue(waitForLabel(of: inputStatus, containing: "Sent page_down"), app.debugDescription)
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
        app.launch()

        let card = app.buttons["WorkspaceCard-WS-DEMO-TABS"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
        // The floating tab bar overlays the bottom of the list; a card under it
        // still reports hittable, but the tap lands on the tab bar.
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

    private func drag(_ element: XCUIElement, from startY: CGFloat, to endY: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
        let end = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    private func waitForLabel(of element: XCUIElement, containing text: String) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
