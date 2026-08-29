import XCTest

@MainActor
final class UploadedAttachmentArtifactUITests: XCTestCase {
    func testUploadedImageAppearsInFilesAndOpensViewer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launchEnvironment["CMUX_SKIP_SPLASH"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_FIXTURES"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_ATTACHMENT_SCENARIO"] = "uploaded-image"
        app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_CACHE_NAMESPACE"] = UUID().uuidString
        app.launchArguments += [
            "--cmux-skip-splash",
            "-cmux.demoMode", "NO",
            "-cmux.localNotificationsEnabled", "NO",
        ]
        addTeardownBlock { app.terminate() }
        app.launch()

        let workspace = app.buttons["agent-lab"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5), app.debugDescription)
        workspace.tap()

        let fileButton = app.buttons["AttachmentFileButton"]
        XCTAssertTrue(fileButton.waitForExistence(timeout: 5), app.debugDescription)
        fileButton.tap()

        let succeeded = app.otherElements["AttachmentBatchSucceededCount"]
        waitFor(succeeded, predicate: "value == '1'", timeout: 20)

        let filesButton = app.buttons["TerminalFilesButton"]
        waitFor(filesButton, predicate: "exists == true AND hittable == true")
        filesButton.tap()

        let imageRow = app.buttons.matching(identifier: "TerminalArtifactRowImage").matching(
            NSPredicate(format: "label CONTAINS %@", "uploaded-camera.png")
        ).firstMatch
        waitFor(imageRow, predicate: "exists == true AND hittable == true")
        imageRow.tap()

        let viewer = app.images["TerminalArtifactViewerImage"]
        waitFor(viewer, predicate: "exists == true")
        XCTAssertEqual(viewer.value as? String, "96x64")
        retainScreenshot(named: "uploaded-image-visible-in-files-viewer")

        let close = app.buttons["TerminalArtifactViewerCloseButton"]
        waitFor(close, predicate: "exists == true AND hittable == true")
        close.tap()
        waitFor(viewer, predicate: "exists == false")
    }

    private func waitFor(
        _ element: XCUIElement,
        predicate format: String,
        timeout: TimeInterval = 10
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: format),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func retainScreenshot(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
