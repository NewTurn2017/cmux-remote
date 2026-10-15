import XCTest
import UIKit

final class WorkspaceAccessoryLayoutUITests: XCTestCase {
    func testOptionUpShortcutSendsModifiedKeyFromBottomRow() {
        continueAfterFailure = false
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        }
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

        assertOptionUpRow(in: app)
        retainScreenshot(named: "option-up-keyboard-hidden")

        let field = app.textFields["CommandComposerField"]
        field.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(keyboard.frame.height, 100, "Exercise a visible software keyboard")
        assertOptionUpRow(in: app)
        let shortcut = app.buttons["OptionUpShortcutButton"]
        XCTAssertLessThanOrEqual(shortcut.frame.maxY, keyboard.frame.minY)
        retainScreenshot(named: "compact-shortcuts-before-send")

        let sent = expectation(
            for: NSPredicate(format: "label == %@", "Sent alt+up"),
            evaluatedWith: app.staticTexts["InputStatusMessage"]
        )
        shortcut.tap()
        wait(for: [sent], timeout: 5)
        XCTAssertTrue(keyboard.exists, "Sending a shortcut must preserve keyboard focus")
        retainScreenshot(named: "option-up-keyboard-visible")

        app.buttons["InputModeToggleButton"].tap()
        XCTAssertTrue(app.textViews["LiveInputField"].waitForExistence(timeout: 5))
        let cleared = expectation(
            for: NSPredicate(format: "label == %@", "Sent esc"),
            evaluatedWith: app.staticTexts["InputStatusMessage"]
        )
        app.buttons["esc"].tap()
        wait(for: [cleared], timeout: 5)
        let liveSent = expectation(
            for: NSPredicate(format: "label == %@", "Sent alt+up"),
            evaluatedWith: app.staticTexts["InputStatusMessage"]
        )
        shortcut.tap()
        wait(for: [liveSent], timeout: 5)
    }

    private func assertOptionUpRow(in app: XCUIApplication) {
        let shortcut = app.buttons["OptionUpShortcutButton"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(shortcut.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "OptionUpShortcutButton").count, 1)
        XCTAssertGreaterThanOrEqual(shortcut.frame.width, 44)
        XCTAssertGreaterThanOrEqual(shortcut.frame.height, 34)
        let space = app.buttons["send space for omx selection"]
        XCTAssertEqual(shortcut.frame.midY, space.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(
            shortcut.frame.minX,
            space.frame.maxX
        )
        let panel = app.otherElements["TerminalAccessoryPanel"]
        XCTAssertLessThanOrEqual(shortcut.frame.maxY, panel.frame.maxY)
    }

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
        assertOptionUpRow(in: app)
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
