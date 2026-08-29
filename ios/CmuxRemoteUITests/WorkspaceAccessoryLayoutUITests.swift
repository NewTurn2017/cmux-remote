import XCTest

final class WorkspaceAccessoryLayoutUITests: XCTestCase {
    func testScrollToBottomStaysBetweenFileAttachmentAndSubmit() {
        continueAfterFailure = false
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

        let workspace = firstWorkspace(in: app)
        XCTAssertTrue(workspace.waitForExistence(timeout: 5), app.debugDescription)
        workspace.tap()

        assertAccessoryOrder(in: app, state: "keyboard hidden")
        retainScreenshot(named: "accessory-scroll-inline-keyboard-hidden")

        let commandField = app.textFields["CommandComposerField"]
        XCTAssertTrue(commandField.waitForExistence(timeout: 5), app.debugDescription)
        commandField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        assertAccessoryOrder(in: app, state: "keyboard visible")
        retainScreenshot(named: "accessory-scroll-inline-keyboard-visible")
    }

    private func assertAccessoryOrder(in app: XCUIApplication, state: String) {
        let panel = app.otherElements["TerminalAccessoryPanel"]
        let fileAttachment = app.buttons["AttachmentFileButton"]
        let scrollToBottom = app.buttons["TerminalScrollToBottomButton"]
        let submit = app.buttons["CommandSubmitButton"]

        for element in [panel, fileAttachment, scrollToBottom, submit] {
            XCTAssertTrue(
                element.waitForExistence(timeout: 5),
                "\(state): missing \(element)\n\(app.debugDescription)"
            )
            XCTAssertTrue(element.isHittable, "\(state): \(element) is not hittable")
        }

        XCTAssertEqual(
            app.buttons.matching(identifier: "TerminalScrollToBottomButton").count,
            1,
            "\(state): scroll-to-bottom must have exactly one placement"
        )
        XCTAssertLessThanOrEqual(
            fileAttachment.frame.maxX,
            scrollToBottom.frame.minX,
            "\(state): scroll-to-bottom must follow file attachment"
        )
        XCTAssertLessThanOrEqual(
            scrollToBottom.frame.maxX,
            submit.frame.minX,
            "\(state): scroll-to-bottom must precede submit"
        )
        XCTAssertGreaterThanOrEqual(scrollToBottom.frame.minY, panel.frame.minY)
        XCTAssertLessThanOrEqual(scrollToBottom.frame.maxY, panel.frame.maxY)
    }

    private func firstWorkspace(in app: XCUIApplication) -> XCUIElement {
        let cards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "WorkspaceCard-")
        )
        if cards.firstMatch.waitForExistence(timeout: 3) {
            return cards.firstMatch
        }
        return app.buttons["Demo Workspace"]
    }

    private func retainScreenshot(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
