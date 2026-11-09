import XCTest

@MainActor
final class DocumentViewerUITests: XCTestCase {
    private static let openCountPrefix = "Loaded from the demo relay: open #"

    override func setUp() async throws {
        continueAfterFailure = false
        await MainActor.run {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    func testMarkdownTabShowsDocumentTitleAndRefreshes() throws {
        let app = launchFixtureApp(scenario: nil)
        openTabTypesWorkspace(in: app)

        let markdownChip = app.buttons["README.md"]
        waitFor(markdownChip, predicate: "exists == true AND hittable == true", in: app)
        markdownChip.tap()

        waitFor(app.otherElements["DocumentViewer"], predicate: "exists == true", in: app)
        waitFor(app.staticTexts["cmux Remote demo"], predicate: "exists == true", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["NonTerminalSurfaceCard"].exists, app.debugDescription)
        attachScreenshot(of: app, named: "markdown-tab-top")

        let openCount = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", Self.openCountPrefix)
        ).firstMatch
        waitFor(openCount, predicate: "exists == true", in: app)
        let before = try XCTUnwrap(
            Int(openCount.label.dropFirst(Self.openCountPrefix.count).filter(\.isNumber)),
            openCount.label
        )

        let refresh = app.buttons["DocumentViewerRefreshButton"]
        waitFor(refresh, predicate: "exists == true AND enabled == true AND hittable == true", in: app)
        refresh.tap()

        let refreshed = app.staticTexts["\(Self.openCountPrefix)\(before + 1)."]
        waitFor(refreshed, predicate: "exists == true", in: app)

        let content = app.scrollViews["DocumentViewerContent"]
        waitFor(content, predicate: "exists == true", in: app)
        content.swipeUp()
        waitFor(app.descendants(matching: .any)["DocumentTable"], predicate: "exists == true", in: app)
        attachScreenshot(of: app, named: "markdown-tab-scrolled")
    }

    func testFilesSheetMarkdownRowOpensViewer() throws {
        let app = launchFixtureApp(scenario: "documents")
        let workspace = app.buttons["agent-lab"]
        waitFor(workspace, predicate: "exists == true AND hittable == true", in: app)
        workspace.tap()

        let filesButton = app.buttons["TerminalFilesButton"]
        waitFor(filesButton, predicate: "exists == true AND hittable == true", in: app)
        filesButton.tap()
        waitFor(app.otherElements["TerminalFilesSheet"], predicate: "exists == true", in: app)

        let documentRow = app.buttons["TerminalArtifactRowDocument"]
        waitFor(documentRow, predicate: "exists == true AND hittable == true", in: app)
        XCTAssertTrue(documentRow.label.contains("notes.md"), app.debugDescription)
        XCTAssertTrue(app.otherElements["TerminalArtifactRowGeneric"].exists, app.debugDescription)
        documentRow.tap()

        let viewer = app.otherElements["DocumentViewer"]
        waitFor(viewer, predicate: "exists == true", in: app)
        waitFor(app.staticTexts["Release notes"], predicate: "exists == true", in: app)
        attachScreenshot(of: app, named: "files-sheet-document")

        app.buttons["DocumentViewerCloseButton"].tap()
        waitFor(viewer, predicate: "exists == false", in: app)
        waitFor(app.otherElements["TerminalFilesSheet"], predicate: "exists == true", in: app)
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchFixtureApp(scenario: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launchEnvironment["CMUX_SKIP_SPLASH"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_FIXTURES"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_CACHE_NAMESPACE"] = UUID().uuidString
        if let scenario {
            app.launchEnvironment["CMUX_UI_TEST_ARTIFACT_SCENARIO"] = scenario
        }
        app.launchArguments += [
            "--cmux-skip-splash",
            "-cmux.demoMode", "NO",
            "-cmux.localNotificationsEnabled", "NO",
        ]
        app.launch()
        return app
    }

    private func openTabTypesWorkspace(in app: XCUIApplication) {
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
        waitFor(app.buttons["localhost:3000"], predicate: "exists == true", in: app)
    }

    private func waitFor(
        _ element: XCUIElement,
        predicate format: String,
        timeout: TimeInterval = 10,
        in app: XCUIApplication
    ) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, app.debugDescription)
    }
}
