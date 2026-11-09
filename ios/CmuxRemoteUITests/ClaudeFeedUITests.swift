import XCTest

@MainActor
final class ClaudeFeedUITests: XCTestCase {
    private let permissionID = "demo-feed-permission"
    private let questionID = "demo-feed-question"
    private let planID = "demo-feed-plan"
    private let multiSelectID = "demo-feed-multi-select"
    private let answerOnMacID = "demo-feed-answer-on-mac"
    private let expiringID = "demo-feed-expiring"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testClaudeTabShowsBadgeAndAllCardKinds() throws {
        let app = launch(scenario: "pending")
        let badge = app.staticTexts["AgentsFeedPendingBadge"]
        wait(for: badge, "exists == true AND label BEGINSWITH '5 '", in: app)
        retainScreenshot(named: "agents-tab-badge-workspaces")

        openFeed(in: app)
        wait(for: app.staticTexts["FeedPendingCount"], "label == '[5]'", in: app)
        for id in [permissionID, questionID] {
            XCTAssertTrue(card(id, in: app).exists, app.debugDescription)
        }
        XCTAssertTrue(app.buttons["Feed-\(permissionID)-allowOnce"].exists)
        XCTAssertTrue(app.buttons["Feed-\(permissionID)-allowAlways"].exists)
        XCTAssertTrue(app.buttons["Feed-\(permissionID)-deny"].exists)
        retainScreenshot(named: "feed-list-permission-question")

        scrollUntilHittable(app.buttons["Feed-\(planID)-approve"], in: app)
        XCTAssertTrue(app.buttons["Feed-\(planID)-autoApprove"].exists)
        XCTAssertTrue(app.buttons["Feed-\(planID)-reject"].exists)
        retainScreenshot(named: "feed-list-plan")
    }

    func testAlwaysAllowAsksConfirmationBeforeSending() throws {
        let app = launch(scenario: "pending")
        openFeed(in: app)
        app.buttons["Feed-\(permissionID)-allowAlways"].tap()

        let confirm = confirmationButton(in: app)
        XCTAssertTrue(card(permissionID, in: app).exists)
        XCTAssertEqual(app.staticTexts["FeedPendingCount"].label, "[5]")
        retainScreenshot(named: "feed-confirm-always-allow")

        confirm.tap()
        wait(for: card(permissionID, in: app), "exists == false", in: app)
        wait(for: app.staticTexts["FeedPendingCount"], "label == '[4]'", in: app)
    }

    func testQuestionSendNeedsAChoiceThenRemovesCard() throws {
        let app = launch(scenario: "pending")
        openFeed(in: app)
        let send = app.buttons["Feed-\(questionID)-Send"]
        scrollUntilHittable(send, in: app)
        XCTAssertFalse(send.isEnabled)

        app.buttons["Feed-\(questionID)-Option-0-1"].tap()
        wait(for: send, "isEnabled == true", in: app)
        retainScreenshot(named: "feed-question-selected")
        send.tap()
        wait(for: card(questionID, in: app), "exists == false", in: app)
    }

    func testPlanApproveRemovesCard() throws {
        let app = launch(scenario: "pending")
        openFeed(in: app)
        let approve = app.buttons["Feed-\(planID)-approve"]
        scrollUntilHittable(approve, in: app)
        approve.tap()
        wait(for: card(planID, in: app), "exists == false", in: app)
        XCTAssertFalse(app.buttons["FeedConfirmReply"].exists)
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    func testMultiSelectSendsAndMixedQuestionsAskForTheMac() throws {
        let app = launch(scenario: "pending")
        openFeed(in: app)
        let send = app.buttons["Feed-\(multiSelectID)-Send"]
        scrollUntilHittable(send, in: app)
        app.buttons["Feed-\(multiSelectID)-Option-0-0"].tap()
        app.buttons["Feed-\(multiSelectID)-Option-0-2"].tap()
        wait(for: send, "isEnabled == true", in: app)

        let answerOnMac = app.staticTexts["Feed-\(answerOnMacID)-AnswerOnMac"]
        scrollUntilHittable(answerOnMac, in: app)
        XCTAssertFalse(app.buttons["Feed-\(answerOnMacID)-Send"].exists)
        retainScreenshot(named: "feed-answer-on-mac")

        scrollUntilHittable(send, in: app, upward: true)
        send.tap()
        wait(for: card(multiSelectID, in: app), "exists == false", in: app)
    }

    func testAlreadyHandledReplyShowsNoticeAndRemovesCard() throws {
        let app = launch(scenario: "already-handled")
        openFeed(in: app)
        app.buttons["Feed-\(permissionID)-deny"].tap()
        wait(for: app.descendants(matching: .any)["FeedAlreadyHandledNotice"], "exists == true", in: app)
        wait(for: card(permissionID, in: app), "exists == false", in: app)
        retainScreenshot(named: "feed-already-handled")
    }

    func testRelayWithoutFeedHidesClaudeTab() throws {
        let legacy = launch(scenario: nil)
        XCTAssertTrue(legacy.buttons["agent-lab"].waitForExistence(timeout: 5), legacy.debugDescription)
        XCTAssertTrue(legacy.buttons["Inbox"].exists)
        XCTAssertFalse(legacy.buttons["Agents"].exists)
        retainScreenshot(named: "tab-bar-without-feed")
        legacy.terminate()

        let unsupported = launch(scenario: "method-not-found")
        XCTAssertTrue(unsupported.buttons["agent-lab"].waitForExistence(timeout: 5), unsupported.debugDescription)
        wait(for: unsupported.buttons["Agents"], "exists == false", in: unsupported, timeout: 10)
        XCTAssertFalse(unsupported.descendants(matching: .any)["FeedErrorBanner"].exists)
        XCTAssertTrue(unsupported.buttons["Inbox"].exists)
    }

    func testFiveTabsFitNarrowIPhoneWidth() throws {
        let app = launch(scenario: "pending", narrowWidth: 375)
        let agents = app.buttons["Agents"]
        wait(for: agents, "exists == true AND hittable == true", in: app)

        let tabBar = app.otherElements["FloatingTabBar"]
        XCTAssertLessThanOrEqual(tabBar.frame.width, 375, "tab bar is wider than the 375pt layout")
        XCTAssertFalse(app.buttons["Claude"].exists)
        let tabs = ["Workspaces", "Active", "Agents", "Inbox", "Settings"].map { app.buttons[$0] }
        var previousMaxX = tabBar.frame.minX
        for tab in tabs {
            XCTAssertTrue(tab.isHittable, "\(tab.label) is not hittable")
            XCTAssertGreaterThanOrEqual(tab.frame.minX, previousMaxX, "\(tab.label) overlaps the previous tab")
            XCTAssertLessThanOrEqual(tab.frame.maxX, tabBar.frame.maxX, "\(tab.label) runs past the tab bar")
            previousMaxX = tab.frame.maxX
        }
        retainScreenshot(named: "tab-bar-five-tabs-375pt")
    }

    func testFeedCardsStayAboveTabBarAndWorkspaceHidesTabBar() throws {
        let app = launch(scenario: "pending")
        openFeed(in: app)
        let lastCard = card(answerOnMacID, in: app)
        scrollUntilHittable(app.staticTexts["Feed-\(answerOnMacID)-AnswerOnMac"], in: app)
        for _ in 0..<3 { app.swipeUp() }

        let tabBar = app.otherElements["FloatingTabBar"]
        XCTAssertTrue(tabBar.exists)
        XCTAssertLessThanOrEqual(lastCard.frame.maxY, tabBar.frame.minY, "last card is covered by the tab bar")
        retainScreenshot(named: "feed-bottom-above-tab-bar")

        app.buttons["Workspaces"].tap()
        let workspace = app.buttons["agent-lab"]
        wait(for: workspace, "exists == true AND hittable == true", in: app)
        workspace.tap()
        wait(for: tabBar, "exists == false", in: app)
        retainScreenshot(named: "workspace-command-panel-without-tab-bar")
    }

    func testExpiringCardDisablesRepliesThenShowsExpiredNotice() throws {
        let app = launch(scenario: "expiring")
        openFeed(in: app)
        XCTAssertTrue(app.staticTexts["Feed-\(permissionID)-Remaining"].exists)
        let remaining = app.staticTexts["Feed-\(expiringID)-Remaining"]
        scrollUntilHittable(app.buttons["Feed-\(expiringID)-allowOnce"], in: app)
        XCTAssertTrue(remaining.exists)
        XCTAssertTrue(app.buttons["Feed-\(expiringID)-allowOnce"].isEnabled)
        retainScreenshot(named: "feed-remaining-time")

        wait(for: app.staticTexts["Feed-\(expiringID)-Expired"], "exists == true", in: app, timeout: 30)
        XCTAssertFalse(app.buttons["Feed-\(expiringID)-allowOnce"].isEnabled)
        XCTAssertFalse(app.buttons["Feed-\(expiringID)-deny"].isEnabled)
        XCTAssertFalse(remaining.exists)
        retainScreenshot(named: "feed-expired-card")

        let reason = app.staticTexts["FeedDeparted-\(expiringID)-Reason"]
        wait(for: reason, "exists == true AND value == 'expired'", in: app, timeout: 10)
        XCTAssertFalse(card(expiringID, in: app).exists)
        wait(for: app.staticTexts["FeedPendingCount"], "label == '[5]'", in: app)
        retainScreenshot(named: "feed-departed-expired")

        wait(for: reason, "exists == false", in: app, timeout: 15)
    }

    // MARK: helpers

    private func launch(scenario: String?, narrowWidth: Int? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launchEnvironment["CMUX_SKIP_SPLASH"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_FIXTURES"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_CACHE_NAMESPACE"] = UUID().uuidString
        if let scenario {
            app.launchEnvironment["CMUX_UI_TEST_FEED_SCENARIO"] = scenario
        }
        if let narrowWidth {
            app.launchEnvironment["CMUX_UI_TEST_NARROW_WIDTH"] = String(narrowWidth)
        }
        app.launchArguments += [
            "--cmux-skip-splash",
            "-cmux.demoMode", "NO",
            "-cmux.localNotificationsEnabled", "NO",
        ]
        app.launch()
        return app
    }

    private func openFeed(in app: XCUIApplication) {
        let agents = app.buttons["Agents"]
        wait(for: agents, "exists == true AND hittable == true", in: app)
        agents.tap()
        wait(for: card(permissionID, in: app), "exists == true", in: app)
    }

    private func confirmationButton(in app: XCUIApplication) -> XCUIElement {
        let byIdentifier = app.buttons.matching(identifier: "FeedConfirmReply").firstMatch
        if byIdentifier.waitForExistence(timeout: 3) { return byIdentifier }
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 2), app.debugDescription)
        return sheet.buttons.element(boundBy: 0)
    }

    private func card(_ requestID: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["FeedCard-\(requestID)"]
    }

    private func wait(
        for element: XCUIElement,
        _ format: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, app.debugDescription)
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = false) {
        var attempts = 0
        while !(element.exists && element.isHittable), attempts < 8 {
            if upward { app.swipeDown() } else { app.swipeUp() }
            attempts += 1
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }

    private func retainScreenshot(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
