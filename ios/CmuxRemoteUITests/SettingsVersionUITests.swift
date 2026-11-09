import XCTest

final class SettingsVersionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSettingsShowsAppVersionWithoutStoreNoticeWhenStoreMatches() throws {
        let app = launch(appStoreFixture: "same", language: "en")
        openSettingsVersionSection(in: app)

        let version = app.staticTexts["SettingsAppVersionValue"]
        XCTAssertNotNil(
            version.label.range(of: #"^\d+\.\d+\.\d+ \(\d+\)$"#, options: .regularExpression),
            "app version must read 'X.Y.Z (build)', got '\(version.label)'"
        )
        XCTAssertFalse(app.descendants(matching: .any)["SettingsAppStoreUpdateNotice"].exists)
        XCTAssertFalse(app.buttons["SettingsAppStoreUpdateButton"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["SettingsUpdateBadge"].exists)
    }

    func testNewerStoreVersionShowsBadgeUntilSettingsIsSeen() throws {
        let app = launch(appStoreFixture: "newer", language: "en")
        let badge = app.descendants(matching: .any)["SettingsUpdateBadge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), app.debugDescription)

        openSettingsVersionSection(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["SettingsAppStoreUpdateNotice"].waitForExistence(timeout: 5))
        let storeButton = app.buttons["SettingsAppStoreUpdateButton"]
        XCTAssertTrue(storeButton.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(storeButton.isHittable)
        XCTAssertTrue(badge.waitForNonExistence(timeout: 5), "opening Settings must mark the store version as seen")
        retainScreenshot(named: "settings-version-en")

        app.buttons["Workspaces"].tap()
        let firstWorkspace = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "WorkspaceCard-")).firstMatch
        XCTAssertTrue(firstWorkspace.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(badge.exists, "badge must stay cleared after Settings was seen")
    }

    func testKoreanSettingsShowsStoreNotice() throws {
        let app = launch(appStoreFixture: "newer", language: "ko")
        openSettingsVersionSection(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["SettingsAppStoreUpdateNotice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["SettingsAppStoreUpdateButton"].waitForExistence(timeout: 5))
        retainScreenshot(named: "settings-version-ko")
    }

    private func launch(appStoreFixture: String, language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launchEnvironment["CMUX_SKIP_SPLASH"] = "1"
        app.launchEnvironment["CMUX_APPSTORE_FIXTURE"] = appStoreFixture
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

    private func openSettingsVersionSection(in app: XCUIApplication) {
        let settingsTab = app.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5), app.debugDescription)
        settingsTab.tap()

        let version = app.staticTexts["SettingsAppVersionValue"]
        XCTAssertTrue(version.waitForExistence(timeout: 5), app.debugDescription)
        let tabBar = app.otherElements["FloatingTabBar"]
        var swipes = 0
        while swipes < 8, !(version.isHittable && version.frame.maxY < tabBar.frame.minY - 60) {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(version.isHittable, app.debugDescription)
    }

    private func retainScreenshot(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
