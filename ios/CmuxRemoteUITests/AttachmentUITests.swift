import XCTest

@MainActor
final class AttachmentUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAttachmentMatrixProgressAndQuotedOrder() throws {
        let app = launchAttachmentApp(scenario: "happy")
        orientForNativeLayout(app)
        openPrimaryWorkspace(in: app)
        focusComposer(in: app)

        let composer = app.textFields["CommandComposerField"]
        composer.typeText("user-edit-sentinel")
        let userDraft = try XCTUnwrap(composer.value as? String)
        XCTAssertFalse(userDraft.isEmpty, app.debugDescription)

        let fileButton = app.buttons["AttachmentFileButton"]
        waitFor(fileButton, predicate: "exists == true AND hittable == true", in: app)
        fileButton.tap()

        let panel = app.otherElements["AttachmentBatchPanel"]
        let succeeded = app.otherElements["AttachmentBatchSucceededCount"]
        let failed = app.otherElements["AttachmentBatchFailedCount"]
        let retry = app.buttons["AttachmentBatchRetryButton"]
        let aggregate = app.otherElements["AttachmentBatchAggregateProgress"]
        let failedItemProgress = app.otherElements["AttachmentItemProgress-3"]
        waitFor(panel, predicate: "exists == true", in: app)
        waitFor(failed, predicate: "value == '1'", timeout: 20, in: app)
        waitFor(aggregate, predicate: "value == '17/21'", in: app)
        waitFor(failedItemProgress, predicate: "value == '0/4'", in: app)

        let partialPaths = [
            "'/Users/demo/Drop/0-it'\\''s report.pdf'",
            "'/Users/demo/Drop/1-it'\\''s contract.docx'",
            "'/Users/demo/Drop/2-it'\\''s hangul.hwp'",
            "'/Users/demo/Drop/4-it'\\''s archive.zip'",
            "'/Users/demo/Drop/5-it'\\''s mystery.unknown'",
        ]
        let partialPathBlock = partialPaths.joined(separator: " ")
        waitFor(
            composer,
            predicate: "value == %@",
            arguments: [userDraft + " " + partialPathBlock],
            timeout: 20,
            in: app
        )

        waitFor(retry, predicate: "exists == true AND hittable == true", in: app)
        retry.tap()
        waitFor(succeeded, predicate: "value == '6'", timeout: 20, in: app)
        waitFor(failed, predicate: "value == '0'", in: app)
        waitFor(retry, predicate: "exists == false", in: app)

        for ordinal in 0..<6 {
            waitFor(
                app.otherElements["AttachmentItemState-\(ordinal)"],
                predicate: "value == 'succeeded'",
                in: app
            )
        }

        let expectedPaths = [
            "'/Users/demo/Drop/0-it'\\''s report.pdf'",
            "'/Users/demo/Drop/1-it'\\''s contract.docx'",
            "'/Users/demo/Drop/2-it'\\''s hangul.hwp'",
            "'/Users/demo/Drop/3-it'\\''s sheet.hwpx'",
            "'/Users/demo/Drop/4-it'\\''s archive.zip'",
            "'/Users/demo/Drop/5-it'\\''s mystery.unknown'",
        ]
        waitFor(
            composer,
            predicate: "value == %@",
            arguments: [userDraft + " " + expectedPaths.joined(separator: " ")],
            timeout: 20,
            in: app
        )
        waitFor(aggregate, predicate: "value == '21/21'", in: app)
        waitFor(failedItemProgress, predicate: "value == '4/4'", in: app)

        assertPanelIsVisibleAboveKeyboard(panel, app: app)
        retainScreenshot(named: screenshotName("attachment-happy"))
    }

    func testAttachmentBatchPreservesKeyboardComposerAdjacency() throws {
        let app = launchAttachmentApp(scenario: "boundary-cancel", largeType: true)
        orientForNativeLayout(app)
        openPrimaryWorkspace(in: app)
        focusComposer(in: app)

        let keyboard = app.keyboards.firstMatch
        let accessory = app.otherElements["TerminalAccessoryPanel"]
        let composer = app.textFields["CommandComposerField"]
        let fileButton = app.buttons["AttachmentFileButton"]
        waitFor(keyboard, predicate: "exists == true", in: app)
        waitFor(accessory, predicate: "exists == true", in: app)
        _ = recordKeyboardGeometry(
            phase: "before-attachment",
            keyboard: keyboard,
            accessory: accessory,
            composer: composer,
            batch: nil,
            app: app
        )

        waitFor(fileButton, predicate: "exists == true AND hittable == true", in: app)
        fileButton.tap()

        let batch = app.otherElements["AttachmentBatchPanel"]
        let cancel = app.buttons["AttachmentBatchCancelButton"]
        waitFor(batch, predicate: "exists == true", in: app)
        waitFor(cancel, predicate: "exists == true AND hittable == true", timeout: 30, in: app)
        let duringUpload = recordKeyboardGeometry(
            phase: "attachment-visible",
            keyboard: keyboard,
            accessory: accessory,
            composer: composer,
            batch: batch,
            app: app
        )
        retainScreenshot(named: screenshotName("attachment-keyboard-adjacency"))

        cancel.tap()
        waitFor(cancel, predicate: "exists == false", in: app)
        let afterCancel = recordKeyboardGeometry(
            phase: "after-cancel",
            keyboard: keyboard,
            accessory: accessory,
            composer: composer,
            batch: batch,
            app: app
        )

        app.buttons["CommandKeyboardDismissButton"].tap()
        waitFor(keyboard, predicate: "exists == false", in: app)
        composer.tap()
        waitFor(keyboard, predicate: "exists == true", in: app)
        let afterDismissRefocus = recordKeyboardGeometry(
            phase: "after-dismiss-refocus",
            keyboard: keyboard,
            accessory: accessory,
            composer: composer,
            batch: batch,
            app: app
        )
        retainScreenshot(named: screenshotName("attachment-keyboard-after-refocus"))

        for sample in [duringUpload, afterCancel, afterDismissRefocus] {
            assertValidKeyboardGeometry(sample, app: app)
        }
    }

    func testOpaqueBlackTerminalViewportWithTokyoNightPanelsAndKeyboardStates() throws {
        let app = launchAttachmentApp(scenario: "happy")
        orientForNativeLayout(app)
        openPrimaryWorkspace(in: app)
        focusComposer(in: app)

        let keyboard = app.keyboards.firstMatch
        let accessory = app.otherElements["TerminalAccessoryPanel"]
        let composer = app.textFields["CommandComposerField"]
        let fileButton = app.buttons["AttachmentFileButton"]
        waitFor(fileButton, predicate: "exists == true AND hittable == true", in: app)
        fileButton.tap()

        let panel = app.otherElements["AttachmentBatchPanel"]
        let failed = app.otherElements["AttachmentBatchFailedCount"]
        let dismiss = app.buttons["AttachmentBatchDismissButton"]
        let submit = app.buttons["CommandSubmitButton"]
        let terminalViewport = app.otherElements["TerminalCanvasBackground"]
        let outerSurround = app.otherElements["WorkspaceSurroundBackground"]
        waitFor(panel, predicate: "exists == true", in: app)
        waitFor(failed, predicate: "value == '1'", timeout: 20, in: app)
        waitFor(terminalViewport, predicate: "value == 'opaque-black'", in: app)
        waitFor(outerSurround, predicate: "value == 'physical-black'", in: app)

        let keyboardVisible = recordKeyboardGeometry(
            phase: "tokyo-night-terminal-physical-black-surround-keyboard-visible",
            keyboard: keyboard,
            accessory: accessory,
            composer: composer,
            batch: panel,
            app: app
        )
        assertValidKeyboardGeometry(keyboardVisible, app: app)
        waitFor(submit, predicate: "exists == true", in: app)
        XCTAssertLessThanOrEqual(submit.frame.width, 46, app.debugDescription)
        XCTAssertLessThanOrEqual(submit.frame.height, 46, app.debugDescription)
        retainScreenshot(named: screenshotName("palette-seam-failure-keyboard-visible"))

        app.buttons["CommandKeyboardDismissButton"].tap()
        waitFor(keyboard, predicate: "exists == false", in: app)
        waitFor(terminalViewport, predicate: "value == 'opaque-black'", in: app)
        waitFor(outerSurround, predicate: "value == 'physical-black'", in: app)
        XCTAssertTrue(app.frame.contains(accessory.frame), app.debugDescription)
        XCTAssertLessThanOrEqual(panel.frame.maxY, accessory.frame.minY + 1, app.debugDescription)
        waitFor(dismiss, predicate: "exists == true AND hittable == true", in: app)
        let draftBeforeDismiss = try XCTUnwrap(composer.value as? String)
        retainScreenshot(named: screenshotName("palette-seam-failure-keyboard-hidden"))

        dismiss.tap()
        waitFor(panel, predicate: "exists == false", in: app)
        XCTAssertEqual(try XCTUnwrap(composer.value as? String), draftBeforeDismiss)
        retainScreenshot(named: screenshotName("attachment-results-dismissed-draft-preserved"))
    }

    func testAttachmentBoundaryDuplicateCancelAndProviderFailure() throws {
        let app = launchAttachmentApp(scenario: "boundary-cancel", largeType: true)
        orientForNativeLayout(app)
        openPrimaryWorkspace(in: app)
        focusComposer(in: app)

        let fileButton = app.buttons["AttachmentFileButton"]
        waitFor(fileButton, predicate: "exists == true AND hittable == true", in: app)
        fileButton.tap()

        let panel = app.otherElements["AttachmentBatchPanel"]
        let succeeded = app.otherElements["AttachmentBatchSucceededCount"]
        let failed = app.otherElements["AttachmentBatchFailedCount"]
        let aggregate = app.otherElements["AttachmentBatchAggregateProgress"]
        let cancel = app.buttons["AttachmentBatchCancelButton"]
        waitFor(panel, predicate: "exists == true", in: app)
        waitFor(succeeded, predicate: "value == '1'", timeout: 30, in: app)
        waitFor(failed, predicate: "value == '2'", timeout: 30, in: app)
        waitFor(aggregate, predicate: "value ENDSWITH '/262144000'", timeout: 30, in: app)
        waitFor(
            app.otherElements["AttachmentItemState-1"],
            predicate: "value == 'uploading'",
            timeout: 30,
            in: app
        )
        waitFor(app.buttons["CommandPhotoAttachButton"], predicate: "enabled == false", in: app)
        waitFor(fileButton, predicate: "enabled == false", in: app)
        waitFor(cancel, predicate: "exists == true AND hittable == true", in: app)
        cancel.tap()

        waitFor(app.otherElements["AttachmentItemState-1"], predicate: "value == 'cancelled'", in: app)
        waitFor(app.otherElements["AttachmentItemProgress-1"], predicate: "value == '0/104857600'", in: app)
        waitFor(aggregate, predicate: "value == '1/262144000'", in: app)
        for ordinal in [2, 3, 4, 5, 8, 9] {
            waitFor(
                app.otherElements["AttachmentItemState-\(ordinal)"],
                predicate: "value == 'unattempted'",
                in: app
            )
        }
        waitFor(app.otherElements["AttachmentItemState-6"], predicate: "value == 'failed:source_unavailable'", in: app)
        waitFor(app.otherElements["AttachmentItemState-7"], predicate: "value == 'failed:file_too_large'", in: app)
        waitFor(cancel, predicate: "exists == false", in: app)

        let duplicateRows = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH 'AttachmentFilename-duplicate.txt-'")
        )
        XCTAssertEqual(duplicateRows.count, 2, app.debugDescription)

        let composer = app.textFields["CommandComposerField"]
        composer.tap()
        composer.typeText(" echo-ready")
        waitFor(composer, predicate: "value CONTAINS 'echo-ready'", in: app)

        assertPanelIsVisibleAboveKeyboard(panel, app: app)
        retainScreenshot(named: screenshotName("attachment-boundary-cancel"))
    }

    private func launchAttachmentApp(scenario: String, largeType: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launchEnvironment["CMUX_SKIP_SPLASH"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_FIXTURES"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_ATTACHMENT_SCENARIO"] = scenario
        app.launchArguments += [
            "--cmux-skip-splash",
            "-cmux.demoMode", "NO",
            "-cmux.localNotificationsEnabled", "NO",
        ]
        if largeType {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityLarge",
            ]
        }
        app.launch()
        return app
    }

    private func openPrimaryWorkspace(in app: XCUIApplication) {
        let workspace = app.buttons["agent-lab"]
        waitFor(workspace, predicate: "exists == true AND hittable == true", in: app)
        workspace.tap()
        waitFor(app.otherElements["TerminalAccessoryPanel"], predicate: "exists == true", in: app)
    }

    private func orientForNativeLayout(_ app: XCUIApplication) {
        guard app.frame.width >= 700 else { return }
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func focusComposer(in app: XCUIApplication) {
        let composer = app.textFields["CommandComposerField"]
        waitFor(composer, predicate: "exists == true AND hittable == true", in: app)
        composer.tap()
        waitFor(app.keyboards.firstMatch, predicate: "exists == true", in: app)
    }

    private struct KeyboardGeometrySample {
        let phase: String
        let gap: CGFloat
        let accessoryFrame: CGRect
        let batchFrame: CGRect
    }

    private func assertValidKeyboardGeometry(
        _ sample: KeyboardGeometrySample,
        app: XCUIApplication
    ) {
        let tolerance: CGFloat = app.frame.width >= 700 ? 8 : 6
        XCTAssertGreaterThanOrEqual(
            sample.gap,
            -tolerance,
            "\(sample.phase): composer overlaps the software keyboard by \(-sample.gap) points."
        )
        XCTAssertLessThanOrEqual(
            sample.gap,
            tolerance,
            "\(sample.phase): blank keyboard band is \(sample.gap) points."
        )
        XCTAssertTrue(app.frame.contains(sample.batchFrame), "\(sample.phase): batch escaped app bounds.")
        XCTAssertLessThanOrEqual(
            sample.batchFrame.maxY,
            sample.accessoryFrame.minY + 1,
            "\(sample.phase): attachment panel collides with the composer."
        )
    }

    private func recordKeyboardGeometry(
        phase: String,
        keyboard: XCUIElement,
        accessory: XCUIElement,
        composer: XCUIElement,
        batch: XCUIElement?,
        app: XCUIApplication
    ) -> KeyboardGeometrySample {
        let assistant = app.otherElements["SystemInputAssistantView"]
        let keyboardTop = assistant.exists
            ? min(assistant.frame.minY, keyboard.frame.minY)
            : keyboard.frame.minY
        let accessoryFrame = accessory.frame
        let batchFrame = batch?.frame ?? .zero
        let geometry = [
            "phase=\(phase)",
            "app=\(app.frame)",
            "keyboard.exists=\(keyboard.exists)",
            "keyboard.frame=\(keyboard.frame)",
            "assistant.exists=\(assistant.exists)",
            "assistant.frame=\(assistant.exists ? assistant.frame : .zero)",
            "keyboardTop=\(keyboardTop)",
            "accessory.frame=\(accessoryFrame)",
            "accessory.value=\(String(describing: accessory.value))",
            "composer.frame=\(composer.frame)",
            "composer.value=\(String(describing: composer.value))",
            "batch.frame=\(batchFrame)",
            "batch.value=\(String(describing: batch?.value))",
        ].joined(separator: "\n")
        print("ATTACHMENT_KEYBOARD_GEOMETRY\n\(geometry)")
        let attachment = XCTAttachment(string: geometry)
        attachment.name = "attachment-keyboard-geometry-\(phase)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return KeyboardGeometrySample(
            phase: phase,
            gap: keyboardTop - accessoryFrame.maxY,
            accessoryFrame: accessoryFrame,
            batchFrame: batchFrame
        )
    }

    private func assertPanelIsVisibleAboveKeyboard(_ panel: XCUIElement, app: XCUIApplication) {
        let composer = app.textFields["CommandComposerField"]
        let accessory = app.otherElements["TerminalAccessoryPanel"]
        XCTAssertFalse(panel.frame.isEmpty, app.debugDescription)
        XCTAssertTrue(panel.isHittable, app.debugDescription)
        XCTAssertTrue(composer.exists, app.debugDescription)
        XCTAssertTrue(accessory.exists, app.debugDescription)
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            let assistantHeight: CGFloat = app.frame.width >= 700 ? 55 : 44
            let assistantTop = keyboard.frame.minY - assistantHeight
            XCTAssertLessThanOrEqual(panel.frame.maxY, assistantTop, app.debugDescription)
        }
        XCTAssertGreaterThanOrEqual(panel.frame.minX, app.frame.minX, app.debugDescription)
        XCTAssertLessThanOrEqual(panel.frame.maxX, app.frame.maxX, app.debugDescription)
    }

    private func waitFor(
        _ element: XCUIElement,
        predicate format: String,
        arguments: [Any] = [],
        timeout: TimeInterval = 10,
        in app: XCUIApplication
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: format, argumentArray: arguments),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            app.debugDescription
        )
    }

    private func screenshotName(_ stem: String) -> String {
        let idiom = XCUIApplication().frame.width >= 700 ? "ipad" : "iphone"
        return "\(stem)-\(idiom)"
    }

    private func retainScreenshot(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
