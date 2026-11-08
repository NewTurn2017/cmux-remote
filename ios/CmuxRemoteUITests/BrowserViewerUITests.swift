import XCTest

@MainActor
final class BrowserViewerUITests: XCTestCase {
    private static let titlePrefix = "cmux Remote demo · #"

    override func setUp() async throws {
        continueAfterFailure = false
        await MainActor.run {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    func testBrowserTabShowsCaptureTitleAndURL() throws {
        let app = launchFixtureApp(refreshSeconds: "600")
        openBrowserTab(in: app)

        let image = app.images["BrowserViewerImage"]
        waitFor(image, predicate: "exists == true", in: app)
        let title = app.staticTexts["BrowserViewerTitle"]
        waitFor(title, predicate: NSPredicate(format: "label BEGINSWITH %@", Self.titlePrefix), in: app)
        XCTAssertEqual(app.staticTexts["BrowserViewerURL"].label, "http://localhost:3000/")
        XCTAssertTrue(app.staticTexts["BrowserViewerUpdatedAt"].exists, app.debugDescription)
        XCTAssertEqual(image.value as? String, "1200x1500")
        XCTAssertFalse(app.descendants(matching: .any)["NonTerminalSurfaceCard"].exists, app.debugDescription)

        let refresh = app.buttons["BrowserViewerRefreshButton"]
        waitFor(refresh, predicate: "exists == true AND hittable == true", in: app)
        XCTAssertGreaterThan(image.frame.height, 200, app.debugDescription)
        XCTAssertGreaterThanOrEqual(image.frame.minY, refresh.frame.maxY, app.debugDescription)
        attachScreenshot(of: app, named: "browser-tab")
    }

    func testRefreshButtonCapturesAgain() throws {
        let app = launchFixtureApp(refreshSeconds: "600")
        openBrowserTab(in: app)

        let before = try captureNumber(in: app)
        let refresh = app.buttons["BrowserViewerRefreshButton"]
        waitFor(refresh, predicate: "exists == true AND enabled == true AND hittable == true", in: app)
        refresh.tap()

        waitFor(
            app.staticTexts["BrowserViewerTitle"],
            predicate: NSPredicate(format: "label == %@", "\(Self.titlePrefix)\(before + 1)"),
            in: app
        )
        attachScreenshot(of: app, named: "browser-tab-refreshed")
    }

    func testAutoRefreshAdvancesWhileVisibleAndLeavesOnTerminalTab() throws {
        let app = launchFixtureApp(refreshSeconds: nil)
        openBrowserTab(in: app)

        let before = try captureNumber(in: app)
        waitFor(
            app.staticTexts["BrowserViewerTitle"],
            predicate: NSPredicate(format: "label == %@", "\(Self.titlePrefix)\(before + 1)"),
            timeout: 15,
            in: app
        )

        let terminalChip = app.buttons["claude-code"]
        waitFor(terminalChip, predicate: "exists == true AND hittable == true", in: app)
        terminalChip.tap()
        waitFor(app.descendants(matching: .any)["TerminalViewport"], predicate: "exists == true", in: app)
        XCTAssertTrue(app.otherElements["BrowserViewer"].waitForNonExistence(timeout: 5), app.debugDescription)
    }

    private func captureNumber(in app: XCUIApplication) throws -> Int {
        let title = app.staticTexts["BrowserViewerTitle"]
        waitFor(title, predicate: NSPredicate(format: "label BEGINSWITH %@", Self.titlePrefix), in: app)
        return try XCTUnwrap(Int(title.label.dropFirst(Self.titlePrefix.count)), title.label)
    }

    private func launchFixtureApp(refreshSeconds: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launchEnvironment["CMUX_SKIP_SPLASH"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_FIXTURES"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_CACHE_NAMESPACE"] = UUID().uuidString
        if let refreshSeconds {
            app.launchEnvironment["CMUX_UI_TEST_BROWSER_REFRESH_SECONDS"] = refreshSeconds
        }
        app.launchArguments += [
            "--cmux-skip-splash",
            "-cmux.demoMode", "NO",
            "-cmux.localNotificationsEnabled", "NO",
        ]
        app.launch()
        return app
    }

    private func openBrowserTab(in app: XCUIApplication) {
        let card = app.buttons["WorkspaceCard-WS-DEMO-TABS"]
        waitFor(card, predicate: "exists == true", in: app)
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

        let browserChip = app.buttons["localhost:3000"]
        waitFor(browserChip, predicate: "exists == true AND hittable == true", in: app)
        browserChip.tap()
        waitFor(app.otherElements["BrowserViewer"], predicate: "exists == true", in: app)
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitFor(
        _ element: XCUIElement,
        predicate format: String,
        timeout: TimeInterval = 10,
        in app: XCUIApplication
    ) {
        waitFor(element, predicate: NSPredicate(format: format), timeout: timeout, in: app)
    }

    private func waitFor(
        _ element: XCUIElement,
        predicate: NSPredicate,
        timeout: TimeInterval = 10,
        in app: XCUIApplication
    ) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, app.debugDescription)
    }
}
