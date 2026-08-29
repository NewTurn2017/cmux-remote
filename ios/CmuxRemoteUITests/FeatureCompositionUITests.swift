import XCTest

@MainActor
final class FeatureCompositionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCapabilitiesEnableFileFeatures() throws {
        let app = launchFileFeatureApp(staleGate: false)
        openPrimaryWorkspace(in: app)

        let attachmentSlot = app.otherElements["AttachmentFeatureControlSlot"]
        let artifactSlot = app.otherElements["TerminalArtifactFeatureControlSlot"]
        let attachmentEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == 'enabled'"),
            object: attachmentSlot
        )
        let artifactEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value BEGINSWITH 'enabled|'"),
            object: artifactSlot
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [attachmentEnabled, artifactEnabled], timeout: 5),
            .completed,
            app.debugDescription
        )

        retainScreenshot(named: "file-feature-controls-enabled")
    }

    func testHostSurfaceSwitchIgnoresStaleFeatureResponses() throws {
        let app = launchFileFeatureApp(staleGate: true)
        openPrimaryWorkspace(in: app)

        let artifactSlot = app.otherElements["TerminalArtifactFeatureControlSlot"]
        let qaState = app.otherElements["FileFeatureContinuationGateState"]
        let blocked = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == 'blocked'"),
            object: qaState
        )
        XCTAssertEqual(XCTWaiter.wait(for: [blocked], timeout: 5), .completed, app.debugDescription)

        let replacementSurface = app.buttons["codex"]
        let replacementReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "exists == true AND value == %@",
                "enabled|SF-DEMO-1B|ready"
            ),
            object: artifactSlot
        )
        let replacementTerminal = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'Codex 2.4.1'"),
            object: app.scrollViews["TerminalViewport"]
        )
        replacementSurface.tap()
        XCTAssertEqual(
            XCTWaiter.wait(for: [replacementReady, replacementTerminal], timeout: 5),
            .completed,
            app.debugDescription
        )

        let terminalInvariant = app.otherElements["FeatureTerminalInvariantState"]
        XCTAssertTrue(terminalInvariant.exists, app.debugDescription)
        let invariantBeforeRelease = stringValue(of: terminalInvariant)
        let terminalBeforeRelease = stringValue(of: app.scrollViews["TerminalViewport"])

        let released = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'released'"),
            object: qaState
        )
        let releaseButton = app.buttons["FeatureFixtureReleaseStaleResponse"]
        releaseButton.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [released], timeout: 5), .completed, app.debugDescription)

        XCTAssertEqual(stringValue(of: artifactSlot), "enabled|SF-DEMO-1B|ready")
        XCTAssertEqual(stringValue(of: terminalInvariant), invariantBeforeRelease)
        XCTAssertEqual(stringValue(of: app.scrollViews["TerminalViewport"]), terminalBeforeRelease)
        XCTAssertTrue(stringValue(of: terminalInvariant).contains("connected"))
        XCTAssertTrue(stringValue(of: terminalInvariant).contains("SF-DEMO-1B"))

        let originalSurface = app.buttons["claude-code"]
        let originalReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                "enabled|SF-DEMO-1A|ready"
            ),
            object: artifactSlot
        )
        originalSurface.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [originalReady], timeout: 5), .completed, app.debugDescription)

        let replacementReadyAgain = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                "enabled|SF-DEMO-1B|ready"
            ),
            object: artifactSlot
        )
        replacementSurface.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [replacementReadyAgain], timeout: 5), .completed, app.debugDescription)

        retainScreenshot(named: "stale-file-feature-response-ignored")
    }

    private func launchFileFeatureApp(staleGate: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launchEnvironment["CMUX_SKIP_SPLASH"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_FIXTURES"] = "1"
        if staleGate {
            app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_STALE_GATE"] = "1"
        }
        app.launchArguments += [
            "--cmux-skip-splash",
            "-cmux.demoMode", "NO",
            "-cmux.localNotificationsEnabled", "NO",
        ]
        app.launch()
        return app
    }

    private func openPrimaryWorkspace(in app: XCUIApplication) {
        let workspace = app.buttons["agent-lab"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: workspace
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, app.debugDescription)
        workspace.tap()
    }

    private func stringValue(of element: XCUIElement) -> String {
        if let value = element.value as? String { return value }
        return element.value.map(String.init(describing:)) ?? ""
    }

    private func retainScreenshot(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
