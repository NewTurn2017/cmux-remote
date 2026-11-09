import XCTest

final class SettingsRelayUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCurrentRelayUpdateNowConfirmsAndShowsProgress() throws {
        let app = launch(relayScenario: "current", language: "en")
        let updateNow = openRelayRows(in: app, scrollTarget: "SettingsRelayUpdateNowButton")

        let version = app.staticTexts["SettingsRelayVersionValue"]
        XCTAssertEqual(version.value as? String, "relay=current")
        XCTAssertEqual(version.label, "2.0.0")
        let state = app.staticTexts["SettingsRelayUpdateState"]
        waitForValue("state=idle", of: state)
        XCTAssertEqual(state.label, "Up to date")
        XCTAssertTrue(app.staticTexts["SettingsRelayLastChecked"].label.contains("Last checked"))
        XCTAssertFalse(app.staticTexts["SettingsRelayAdhocWarning"].exists)
        XCTAssertFalse(app.staticTexts["SettingsRelayManualUpdateGuide"].exists)
        XCTAssertTrue(updateNow.isEnabled)
        retainScreenshot(named: "settings-relay-current-en")

        updateNow.tap()
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(confirm.label.contains("Update the relay now?"), confirm.label)
        confirm.buttons["Update"].tap()

        waitForValue("state=checking", of: state)
        XCTAssertFalse(updateNow.isEnabled, "Update Now must be disabled while the relay checks")

        let result = app.staticTexts["SettingsRelayUpdateResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(result.label, "Already up to date")
        waitForValue("state=idle", of: state)
        XCTAssertTrue(updateNow.isEnabled)
    }

    func testStagedRelayShowsReadyUpdateAndReportsTheNewVersion() throws {
        let app = launch(relayScenario: "staged", language: "en")
        let updateNow = openRelayRows(in: app, scrollTarget: "SettingsRelayUpdateNowButton")

        let state = app.staticTexts["SettingsRelayUpdateState"]
        waitForValue("state=staged", of: state)
        XCTAssertTrue(state.label.contains("2.0.1"), state.label)
        XCTAssertTrue(app.staticTexts["SettingsRelayAdhocWarning"].exists, app.debugDescription)
        XCTAssertTrue(updateNow.isEnabled)
        retainScreenshot(named: "settings-relay-staged")

        updateNow.tap()
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.buttons["Update"].tap()

        waitForValue("state=applying", of: state)
        XCTAssertFalse(updateNow.isEnabled)

        let result = app.staticTexts["SettingsRelayUpdateResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(result.label, "Updated 2.0.0 → 2.0.1")
        XCTAssertEqual(app.staticTexts["SettingsRelayVersionValue"].label, "2.0.1")
    }

    func testLegacyRelayShowsUnknownVersionAndManualGuide() throws {
        let app = launch(relayScenario: "legacy", language: "en")
        let link = openRelayRows(in: app, scrollTarget: "SettingsRelayManualUpdateLink")

        let version = app.staticTexts["SettingsRelayVersionValue"]
        waitForValue("relay=legacy", of: version)
        XCTAssertEqual(version.label, "Unknown (before 2.0)")
        XCTAssertTrue(app.staticTexts["SettingsRelayManualUpdateGuide"].label.contains("./scripts/install-launchd.sh"))
        XCTAssertTrue(link.isHittable)
        XCTAssertFalse(app.buttons["SettingsRelayUpdateNowButton"].exists)
        XCTAssertFalse(app.staticTexts["SettingsRelayUpdateState"].exists)
        retainScreenshot(named: "settings-relay-legacy")
    }

    func testKoreanCurrentRelay() throws {
        let app = launch(relayScenario: "current", language: "ko")
        let updateNow = openRelayRows(in: app, scrollTarget: "SettingsRelayUpdateNowButton")

        let state = app.staticTexts["SettingsRelayUpdateState"]
        waitForValue("state=idle", of: state)
        XCTAssertEqual(state.label, "최신 버전")
        XCTAssertTrue(app.staticTexts["SettingsRelayLastChecked"].label.contains("마지막 확인"))
        XCTAssertTrue(updateNow.isEnabled)
        retainScreenshot(named: "settings-relay-current-ko")
    }

    private func launch(relayScenario: String, language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launchEnvironment["CMUX_SKIP_SPLASH"] = "1"
        app.launchEnvironment["CMUX_APPSTORE_FIXTURE"] = "same"
        app.launchEnvironment["CMUX_UI_TEST_RELAY_SCENARIO"] = relayScenario
        app.launchArguments += [
            "--cmux-skip-splash",
            "-cmux.demoMode", "NO",
            "-cmux.localNotificationsEnabled", "NO",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language == "ko" ? "ko_KR" : "en_US",
        ]
        addTeardownBlock { app.terminate() }
        app.launch()
        return app
    }

    private func openRelayRows(in app: XCUIApplication, scrollTarget identifier: String) -> XCUIElement {
        let settingsTab = app.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5), app.debugDescription)
        settingsTab.tap()

        let target = app.buttons[identifier]
        XCTAssertTrue(target.waitForExistence(timeout: 10), app.debugDescription)
        let tabBar = app.otherElements["FloatingTabBar"]
        var swipes = 0
        while swipes < 8, !(target.isHittable && target.frame.maxY < tabBar.frame.minY - 20) {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(target.isHittable, app.debugDescription)
        return target
    }

    private func waitForValue(_ value: String, of element: XCUIElement, timeout: TimeInterval = 10) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "\(element) never reached \(value); last value \(String(describing: element.value))"
        )
    }

    private func retainScreenshot(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
