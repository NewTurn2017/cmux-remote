import XCTest

@MainActor
final class ClaudeTranscriptUITests: XCTestCase {
    private let liveSession = "demo-claude-live"
    private let idleSession = "demo-claude-idle"
    private let missingSession = "demo-claude-missing"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSessionListShowsLiveStatusPlaceAndOrder() throws {
        let app = launch(feed: "pending", transcript: "sessions")
        openHistory(in: app)

        let live = app.buttons["ClaudeSession-\(liveSession)"]
        let idle = app.buttons["ClaudeSession-\(idleSession)"]
        wait(for: idle, "exists == true", in: app)
        XCTAssertTrue(live.label.contains("LIVE"), live.label)
        XCTAssertTrue(live.label.contains("agent-lab · feat/feed-cache"), live.label)
        XCTAssertFalse(idle.label.contains("LIVE"), idle.label)
        XCTAssertTrue(idle.label.contains("notes-api · main"), idle.label)
        XCTAssertLessThan(live.frame.minY, idle.frame.minY, "sessions are not newest first")
        XCTAssertEqual(app.staticTexts["ClaudeSessionCount"].label, "[4]")
        retainScreenshot(named: "transcript-session-list")
    }

    func testTranscriptOpensAtLatestAndLoadsOlderPageOnTopScroll() throws {
        let app = launch(feed: "pending", transcript: "sessions")
        openTranscript(idleSession, in: app)
        let newest = entry("idle-e45", in: app)
        wait(for: newest, "exists == true AND hittable == true", in: app)
        XCTAssertFalse(entry("idle-e16", in: app).exists)
        XCTAssertFalse(app.staticTexts["TranscriptStart"].exists)
        retainScreenshot(named: "transcript-latest-page")

        let oldestOfLatestPage = entry("idle-e31", in: app)
        let splitMessageText = app.buttons["TranscriptTool-idle-e31-1"]
        var swipes = 0
        while !splitMessageText.exists, swipes < 10 {
            scrollView(in: app).swipeDown(velocity: .slow)
            swipes += 1
        }
        wait(for: splitMessageText, "exists == true", in: app)
        XCTAssertTrue(oldestOfLatestPage.exists)
        wait(for: entry("idle-e33", in: app), "exists == true AND hittable == true", in: app)
        wait(for: entry("idle-e34", in: app), "exists == true AND hittable == true", in: app)
        XCTAssertFalse(entry("idle-e30", in: app).exists, "the message split by the page boundary was not merged")
        XCTAssertFalse(app.staticTexts["TranscriptStart"].exists, "more than one older page was attached")
        retainScreenshot(named: "transcript-older-page-attached")

        let start = app.staticTexts["TranscriptStart"]
        swipes = 0
        while !(start.exists && start.isHittable), swipes < 20 {
            scrollView(in: app).swipeDown(velocity: .slow)
            swipes += 1
        }
        XCTAssertTrue(start.exists && start.isHittable, app.debugDescription)
        let startLeaves = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR hittable == false"),
            object: start
        )
        startLeaves.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [startLeaves], timeout: 1), .completed, "the start of the conversation did not stay on screen")
        XCTAssertTrue(entry("idle-e01", in: app).exists)
        retainScreenshot(named: "transcript-start-reached")
    }

    func testOlderPageKeepsOnScreenRowsInPlace() throws {
        let app = launch(feed: "pending", transcript: "sessions")
        openTranscript(idleSession, in: app)
        wait(for: entry("idle-e45", in: app), "exists == true AND hittable == true", in: app)
        let scroll = scrollView(in: app)
        let splitMessageText = app.buttons["TranscriptTool-idle-e31-1"]
        let oneLine: CGFloat = 44

        var before = onScreenLatestPageRows(in: app)
        var dragMovement: CGFloat?
        for _ in 0..<10 {
            drag(scroll, downBy: 250)
            let after = onScreenLatestPageRows(in: app)
            let kept = Set(before.keys).intersection(after.keys)
            if splitMessageText.exists {
                let movement = try XCTUnwrap(dragMovement, "the older page attached before one plain drag could be measured")
                XCTAssertFalse(kept.isEmpty, "no row that was on screen before the older page attached is still on screen")
                for id in kept.sorted() {
                    XCTAssertEqual(after[id]!, before[id]! + movement, accuracy: oneLine, "\(id) moved when the older page attached")
                }
                XCTAssertFalse(app.staticTexts["TranscriptStart"].exists, "more than one older page was attached")
                retainScreenshot(named: "transcript-older-page-kept-in-place")
                return
            }
            if let id = kept.sorted().first { dragMovement = after[id]! - before[id]! }
            before = after
        }
        XCTFail("the older page never attached")
    }

    func testToolRowExpandsAndCollapses() throws {
        let app = launch(feed: "pending", transcript: "sessions")
        openTranscript(idleSession, in: app)
        let tool = app.buttons["TranscriptTool-idle-e42-1"]
        wait(for: tool, "exists == true", in: app)
        scrollUntilHittable(tool, in: app)
        XCTAssertEqual(tool.value as? String, "collapsed")
        let detail = app.staticTexts["TranscriptToolDetail-idle-e42-1"]
        XCTAssertFalse(detail.exists)
        retainScreenshot(named: "transcript-text-and-tool-collapsed")

        tool.tap()
        wait(for: detail, "exists == true", in: app)
        XCTAssertEqual(tool.value as? String, "expanded")
        retainScreenshot(named: "transcript-tool-expanded")

        tool.tap()
        wait(for: detail, "exists == false", in: app)
    }

    func testTranscriptBottomStaysAboveTabBar() throws {
        let app = launch(feed: "pending", transcript: "sessions")
        openTranscript(idleSession, in: app)
        let newest = entry("idle-e45", in: app)
        wait(for: newest, "exists == true AND hittable == true", in: app)
        app.swipeUp()

        let tabBar = app.otherElements["FloatingTabBar"]
        XCTAssertTrue(tabBar.exists)
        XCTAssertLessThanOrEqual(newest.frame.maxY, tabBar.frame.minY, "the newest message is covered by the tab bar")
        retainScreenshot(named: "transcript-bottom-above-tab-bar")
    }

    func testLiveSessionRefreshShowsNewMessage() throws {
        let app = launch(feed: "pending", transcript: "sessions")
        openTranscript(liveSession, in: app)
        wait(for: entry("live-e45", in: app), "exists == true", in: app)
        XCTAssertTrue(app.staticTexts["TranscriptLive"].exists)

        let refresh = app.buttons["TranscriptRefresh"]
        wait(for: refresh, "isEnabled == true", in: app)
        refresh.tap()
        wait(for: entry("live-e46", in: app), "exists == true", in: app)
        retainScreenshot(named: "transcript-live-refreshed")
    }

    func testHistoryHiddenWithoutCapabilityAndMissingSessionShowsNotFound() throws {
        let feedOnly = launch(feed: "pending", transcript: nil)
        openAgents(in: feedOnly)
        wait(for: feedOnly.descendants(matching: .any)["FeedCard-demo-feed-permission"], "exists == true", in: feedOnly)
        XCTAssertFalse(feedOnly.descendants(matching: .any)["AgentsSectionPicker"].exists)
        XCTAssertFalse(feedOnly.buttons["AgentsSection-history"].exists)
        feedOnly.terminate()

        let historyOnly = launch(feed: nil, transcript: "sessions")
        openAgents(in: historyOnly)
        let missing = historyOnly.buttons["ClaudeSession-\(missingSession)"]
        wait(for: missing, "exists == true", in: historyOnly)
        XCTAssertFalse(historyOnly.descendants(matching: .any)["AgentsSectionPicker"].exists)
        scrollUntilHittable(missing, in: historyOnly, upward: false)
        missing.tap()
        wait(for: historyOnly.staticTexts["TranscriptSessionNotFound"], "exists == true", in: historyOnly)
        retainScreenshot(named: "transcript-session-not-found")
        historyOnly.buttons["TranscriptBackToSessions"].tap()
        wait(for: historyOnly.buttons["ClaudeSession-\(idleSession)"], "exists == true", in: historyOnly)
        historyOnly.terminate()

        let unsupported = launch(feed: "pending", transcript: "method-not-found")
        openAgents(in: unsupported)
        let history = unsupported.buttons["AgentsSection-history"]
        wait(for: history, "exists == true AND hittable == true", in: unsupported)
        history.tap()
        wait(for: unsupported.descendants(matching: .any)["AgentsSectionPicker"], "exists == false", in: unsupported, timeout: 10)
        wait(for: unsupported.descendants(matching: .any)["FeedCard-demo-feed-permission"], "exists == true", in: unsupported)
        XCTAssertFalse(unsupported.descendants(matching: .any)["ClaudeSessionListError"].exists)
    }

    // MARK: helpers

    private func launch(feed: String?, transcript: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launchEnvironment["CMUX_SKIP_SPLASH"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_FIXTURES"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_CACHE_NAMESPACE"] = UUID().uuidString
        if let feed {
            app.launchEnvironment["CMUX_UI_TEST_FEED_SCENARIO"] = feed
        }
        if let transcript {
            app.launchEnvironment["CMUX_UI_TEST_TRANSCRIPT_SCENARIO"] = transcript
        }
        app.launchArguments += [
            "--cmux-skip-splash",
            "-cmux.demoMode", "NO",
            "-cmux.localNotificationsEnabled", "NO",
        ]
        app.launch()
        return app
    }

    private func openAgents(in app: XCUIApplication) {
        let agents = app.buttons["Agents"]
        wait(for: agents, "exists == true AND hittable == true", in: app)
        agents.tap()
    }

    private func openHistory(in app: XCUIApplication) {
        openAgents(in: app)
        let history = app.buttons["AgentsSection-history"]
        wait(for: history, "exists == true AND hittable == true", in: app)
        history.tap()
        wait(for: app.buttons["ClaudeSession-\(liveSession)"], "exists == true", in: app)
    }

    private func openTranscript(_ sessionID: String, in app: XCUIApplication) {
        openHistory(in: app)
        let row = app.buttons["ClaudeSession-\(sessionID)"]
        wait(for: row, "exists == true AND hittable == true", in: app)
        row.tap()
        wait(for: app.buttons["TranscriptBack"], "exists == true", in: app)
    }

    /// Drags without a fling: the finger holds still at the end, so the content moves only by the drag.
    private func drag(_ element: XCUIElement, downBy distance: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = start.withOffset(CGVector(dx: 0, dy: distance))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
    }

    /// Top edges of the newest page's rows that are fully on screen above the tab bar. The first
    /// row is left out because the older page merges a message into it.
    private func onScreenLatestPageRows(in app: XCUIApplication) -> [String: CGFloat] {
        let visibleTop = scrollView(in: app).frame.minY
        let visibleBottom = min(scrollView(in: app).frame.maxY, app.otherElements["FloatingTabBar"].frame.minY)
        var rows: [String: CGFloat] = [:]
        for number in [32, 33, 34, 36, 37, 38, 40, 41, 42, 44, 45] {
            let row = entry("idle-e\(number)", in: app)
            guard row.exists else { continue }
            let frame = row.frame
            if frame.minY >= visibleTop, frame.maxY <= visibleBottom { rows["idle-e\(number)"] = frame.minY }
        }
        return rows
    }

    private func entry(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["TranscriptEntry-\(id)"]
    }

    private func scrollView(in app: XCUIApplication) -> XCUIElement {
        let scroll = app.scrollViews["ClaudeTranscriptScroll"]
        return scroll.exists ? scroll : app.scrollViews.firstMatch
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

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        var attempts = 0
        while !(element.exists && element.isHittable), attempts < 8 {
            if upward { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
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
