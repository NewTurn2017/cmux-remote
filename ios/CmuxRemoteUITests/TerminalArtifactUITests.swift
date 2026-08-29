import XCTest

@MainActor
final class TerminalArtifactUITests: XCTestCase {
    private var liveApp: XCUIApplication?
    private var liveCleanupCommand: String?
    private var liveCleanupSentinel: String?

    override func setUp() async throws {
        continueAfterFailure = false
        await MainActor.run {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    override func tearDown() async throws {
        cleanUpLiveFixtureIfNeeded()
    }

    private func cleanUpLiveFixtureIfNeeded() {
        if let liveApp,
           liveCleanupCommand != nil,
           liveCleanupSentinel != nil
        {
            confirmLiveCleanup(in: liveApp, phase: "teardown-fallback")
        }
        liveApp = nil
    }

    func testArtifactViewerHappyPaths() throws {
        let app = launchArtifactApp(scenario: "happy", koreanLargeType: true)
        openPrimaryWorkspace(in: app)

        let terminal = app.scrollViews["TerminalViewport"]
        let invariant = app.otherElements["FeatureTerminalInvariantState"]
        waitFor(terminal, predicate: "exists == true", in: app)
        waitFor(invariant, predicate: "exists == true", in: app)
        let terminalBefore = stringValue(of: terminal)
        let invariantBefore = stringValue(of: invariant)

        let filesButton = app.buttons["TerminalFilesButton"]
        waitFor(filesButton, predicate: "exists == true AND hittable == true", in: app)
        XCTAssertGreaterThanOrEqual(filesButton.frame.width, 44)
        XCTAssertGreaterThanOrEqual(filesButton.frame.height, 44)
        filesButton.tap()

        let sheet = app.otherElements["TerminalFilesSheet"]
        waitFor(sheet, predicate: "exists == true", in: app)
        XCTAssertTrue(terminal.exists, app.debugDescription)
        XCTAssertFalse(terminal.frame.intersection(sheet.frame).isEmpty, app.debugDescription)

        let imageRow = app.buttons["TerminalArtifactRowImage"]
        let genericRow = app.otherElements["TerminalArtifactRowGeneric"]
        waitFor(imageRow, predicate: "exists == true", in: app)
        waitFor(genericRow, predicate: "exists == true", in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "TerminalArtifactRowImage").count, 1, app.debugDescription)
        XCTAssertEqual(app.buttons.matching(identifier: "TerminalArtifactRowGeneric").count, 0, app.debugDescription)
        XCTAssertTrue(imageRow.label.contains("terminal-visible.png"), app.debugDescription)
        XCTAssertTrue(genericRow.label.contains("build-notes.pdf"), app.debugDescription)
        XCTAssertTrue(genericRow.label.contains("application/pdf"), app.debugDescription)
        waitFor(app.images["TerminalArtifactThumbnailImage"], predicate: "exists == true", in: app)
        waitFor(app.descendants(matching: .any)["TerminalArtifactStateGeneric"], predicate: "exists == true", in: app)
        retainScreenshot(named: "terminal-artifact-sheet-portrait-ko-large")

        imageRow.tap()
        let viewerImage = app.images["TerminalArtifactViewerImage"]
        waitFor(viewerImage, predicate: "exists == true", timeout: 20, in: app)
        XCTAssertEqual(stringValue(of: viewerImage), "96x64", app.debugDescription)
        let close = app.buttons["TerminalArtifactViewerCloseButton"]
        waitFor(close, predicate: "exists == true AND hittable == true", in: app)
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        retainScreenshot(named: "terminal-artifact-viewer-portrait")
        close.tap()
        waitFor(viewerImage, predicate: "exists == false", in: app)
        waitFor(app.otherElements["TerminalArtifactViewerTempCount"], predicate: "value == '0'", in: app)

        for _ in 0..<3 {
            imageRow.tap()
            waitFor(viewerImage, predicate: "exists == true", timeout: 20, in: app)
            waitFor(close, predicate: "exists == true AND hittable == true", in: app)
            close.tap()
            waitFor(viewerImage, predicate: "exists == false", in: app)
            waitFor(app.otherElements["TerminalArtifactViewerTempCount"], predicate: "value == '0'", in: app)
        }

        XCTAssertEqual(stringValue(of: terminal), terminalBefore)
        XCTAssertEqual(stringValue(of: invariant), invariantBefore)
        dismissArtifactPresentation(in: app)

        if app.frame.width >= 700 {
            rotate(to: .landscapeLeft, expectedState: "landscape", in: app)
            waitFor(filesButton, predicate: "exists == true AND hittable == true", in: app)
            filesButton.tap()
            waitFor(sheet, predicate: "exists == true", in: app)
            assertContained(sheet.frame, in: app.frame)
            XCTAssertLessThanOrEqual(sheet.frame.width, 520)
            retainScreenshot(named: "terminal-artifact-popover-landscape")
            dismissArtifactPresentation(in: app)

        }
    }

    func testArtifactViewerStaleCorruptOversizedFailures() throws {
        let app = launchArtifactApp(scenario: "failures")
        openPrimaryWorkspace(in: app)

        let terminal = app.scrollViews["TerminalViewport"]
        let invariant = app.otherElements["FeatureTerminalInvariantState"]
        waitFor(terminal, predicate: "exists == true", in: app)
        waitFor(invariant, predicate: "exists == true", in: app)
        let invariantBefore = stringValue(of: invariant)

        let filesButton = app.buttons["TerminalFilesButton"]
        waitFor(filesButton, predicate: "exists == true AND hittable == true", in: app)
        filesButton.tap()
        let sheet = app.otherElements["TerminalFilesSheet"]
        waitFor(sheet, predicate: "exists == true", in: app)

        for identifier in [
            "TerminalArtifactStateStale",
            "TerminalArtifactStateCorrupt",
            "TerminalArtifactStateOversized",
            "TerminalArtifactStateByteCap",
            "TerminalArtifactStatePixelCap",
            "TerminalArtifactStateUnavailable",
            "TerminalArtifactStateError",
        ] {
            waitFor(app.descendants(matching: .any)[identifier], predicate: "exists == true", in: app)
        }
        XCTAssertFalse(app.images["TerminalArtifactViewerImage"].exists, app.debugDescription)
        waitFor(app.otherElements["TerminalArtifactViewerTempCount"], predicate: "value == '0'", in: app)
        sheet.swipeUp()
        waitFor(
            app.descendants(matching: .any)["TerminalArtifactStateError"],
            predicate: "hittable == true",
            in: app
        )
        retainScreenshot(named: "terminal-artifact-failure-matrix-all-states")

        dismissArtifactPresentation(in: app)
        let composer = app.textFields["CommandComposerField"]
        waitFor(composer, predicate: "exists == true AND hittable == true", in: app)
        composer.tap()
        composer.typeText("artifact-input-sentinel")
        waitFor(composer, predicate: "value CONTAINS 'artifact-input-sentinel'", in: app)
        XCTAssertTrue(stringValue(of: invariant).contains("connected"))
        XCTAssertEqual(normalizedInvariant(stringValue(of: invariant)), normalizedInvariant(invariantBefore))
        waitFor(app.otherElements["TerminalArtifactViewerTempCount"], predicate: "value == '0'", in: app)
        retainScreenshot(named: "terminal-artifact-terminal-input-after-failures")
    }

    func testArtifactSourceLoadingAndFileChangedStates() throws {
        let app = launchArtifactApp(scenario: "source-states")
        openPrimaryWorkspace(in: app)

        let filesButton = app.buttons["TerminalFilesButton"]
        waitFor(filesButton, predicate: "exists == true AND hittable == true", in: app)
        filesButton.tap()
        waitFor(app.otherElements["TerminalFilesSheet"], predicate: "exists == true", in: app)
        let gate = app.otherElements["FileFeatureContinuationGateState"]
        waitFor(gate, predicate: "value == 'thumbnail-blocked'", in: app)
        waitFor(app.descendants(matching: .any)["TerminalArtifactStateLoading"], predicate: "exists == true", in: app)
        retainScreenshot(named: "terminal-artifact-source-loading")

        let release = app.buttons["FeatureFixtureReleaseStaleResponse"]
        waitFor(release, predicate: "exists == true AND hittable == true", in: app)
        release.tap()
        waitFor(app.descendants(matching: .any)["TerminalArtifactStateFileChanged"], predicate: "exists == true", in: app)
        retainScreenshot(named: "terminal-artifact-source-file-changed")
    }

    func testArtifactConstrainedWidthHarness() throws {
        let app = launchArtifactApp(scenario: "constrained-width")
        openPrimaryWorkspace(in: app)

        let harness = app.otherElements["TerminalArtifactConstrainedWidthHarness"]
        waitFor(harness, predicate: "exists == true", in: app)
        let normalizedHarnessValue = stringValue(of: harness).replacingOccurrences(of: ",", with: "")
        if app.frame.width < 1_000 {
            XCTAssertEqual(
                normalizedHarnessValue,
                "app=\(Int(app.frame.width))|container=\(Int(app.frame.width))"
            )
            let sourceAccessory = app.otherElements["TerminalAccessoryPanel"]
            waitFor(sourceAccessory, predicate: "exists == true", in: app)
            assertContained(sourceAccessory.frame, in: app.frame)
            return
        }
        let geometryTolerance: CGFloat = 4
        let reportedAppWidth = try XCTUnwrap(widthValue(named: "app", in: normalizedHarnessValue))
        let reportedContainerWidth = try XCTUnwrap(widthValue(named: "container", in: normalizedHarnessValue))
        XCTAssertEqual(reportedAppWidth, app.frame.width, accuracy: geometryTolerance)
        XCTAssertEqual(reportedContainerWidth, 640, accuracy: geometryTolerance)
        let containerFrame = CGRect(
            x: (app.frame.width - reportedContainerWidth) / 2,
            y: app.frame.minY,
            width: reportedContainerWidth,
            height: app.frame.height
        )
        assertContained(containerFrame, in: app.frame)
        XCTAssertGreaterThan(app.frame.width, containerFrame.width)
        let sourceAccessory = app.otherElements["TerminalAccessoryPanel"]
        waitFor(sourceAccessory, predicate: "exists == true", in: app)
        assertContained(sourceAccessory.frame, in: containerFrame)

        let filesButton = app.buttons["TerminalFilesButton"]
        waitFor(filesButton, predicate: "exists == true AND hittable == true", in: app)
        filesButton.tap()
        let popover = app.otherElements["TerminalFilesSheet"]
        waitFor(popover, predicate: "exists == true", in: app)
        XCTAssertEqual(popover.frame.width, 480, accuracy: geometryTolerance)
        XCTAssertEqual(popover.frame.height, 560, accuracy: geometryTolerance)
        assertContained(popover.frame, in: containerFrame)
        XCTAssertGreaterThan(containerFrame.width, popover.frame.width)
        XCTAssertGreaterThan(containerFrame.height, popover.frame.height)
        retainScreenshot(named: "terminal-artifact-constrained-width-640-popover")
    }

    func testCleanupCommandFailureCannotEmitSuccessAndKeepsFallbackArmed() throws {
        let sentinel = "CMUX_QA_CLEANUP_TEST"
        let command = cleanupCommand(
            generatedImage: "/tmp/cmux-qa-cleanup-directory",
            returnedPaths: [
                "/tmp/cmux-qa-report.pdf",
                "/tmp/cmux-qa-contract's.docx",
                "/tmp/cmux-qa-hangul.hwp",
                "/tmp/cmux-qa-sheet.hwpx",
                "/tmp/cmux-qa-archive.zip",
            ],
            sentinel: sentinel
        )

        liveCleanupCommand = command
        liveCleanupSentinel = sentinel
        XCTAssertTrue(command.hasPrefix("set -e; rm -f -- "))
        XCTAssertEqual(command.components(separatedBy: "test ! -e ").count - 1, 6)
        XCTAssertTrue(command.contains("'\\''"))
        XCTAssertFalse(command.contains("; printf"))
        XCTAssertTrue(command.contains("printf '\\nCMUX_QA_CLEANUP_%s\\n'"))
        XCTAssertNotNil(liveCleanupCommand)
        XCTAssertNotNil(liveCleanupSentinel)
    }

    func testLiveAttachmentFixtureContractUsesExactlyFiveRequiredFiles() throws {
        let app = launchArtifactApp(scenario: "happy", attachmentScenario: "live-matrix")
        openPrimaryWorkspace(in: app)
        let fileButton = app.buttons["AttachmentFileButton"]
        waitFor(fileButton, predicate: "exists == true AND hittable == true", in: app)
        fileButton.tap()
        waitFor(app.otherElements["AttachmentBatchSucceededCount"], predicate: "value == '5'", timeout: 30, in: app)
        let draft = stringValue(of: app.textFields["CommandComposerField"])
        let returnedPaths = shellQuotedPaths(in: draft).map(shellUnquotedPath)
        XCTAssertEqual(returnedPaths.count, 5, "fixture_path_count=\(returnedPaths.count)")
        let requiredExtensions: Set<String> = ["pdf", "docx", "hwp", "hwpx", "zip"]
        XCTAssertEqual(Set(returnedPaths.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }), requiredExtensions)
        for requiredExtension in requiredExtensions {
            XCTAssertEqual(returnedPaths.filter { URL(fileURLWithPath: $0).pathExtension.lowercased() == requiredExtension }.count, 1, "fixture_extension=\(requiredExtension)")
        }
        XCTAssertFalse(draft.contains(".unknown"), "fixture_contains_unknown=true")
    }

    func testLiveRelayAttachmentAndArtifactMatrix() throws {
        guard ProcessInfo.processInfo.environment["CMUX_UI_TEST_LIVE_RELAY"] == "1" else {
            let receipt = XCTAttachment(string: "NON_LIVE_GATE_NO_OP: live relay behavior was not executed")
            receipt.name = "terminal-artifact-live-gate-no-op"
            receipt.lifetime = .keepAlways
            add(receipt)
            return
        }

        let app = launchArtifactApp(scenario: "live", fakeRelay: false, attachmentScenario: "live-matrix")
        liveApp = app
        let generatedImage = "/tmp/cmux-remote-qa.png"
        let cleanupSentinel = "CMUX_QA_CLEANUP_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        liveCleanupSentinel = cleanupSentinel
        liveCleanupCommand = cleanupCommand(
            generatedImage: generatedImage,
            returnedPaths: [],
            sentinel: cleanupSentinel
        )

        openFirstAvailableWorkspace(in: app)
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAD0lEQVR42mNkYPj/n4GBgQEAEwQCAJUbB9sAAAAASUVORK5CYII="
        sendCommand(
            "printf %s '\(pngBase64)' | base64 -d > '\(generatedImage)'; printf '\\n\(generatedImage)\\n'",
            in: app
        )

        let fileButton = app.buttons["AttachmentFileButton"]
        waitForLive(fileButton, predicate: "exists == true AND hittable == true", timeout: 20, code: "attachment_button")
        fileButton.tap()
        let succeeded = app.otherElements["AttachmentBatchSucceededCount"]
        waitForLive(succeeded, predicate: "value == '5'", timeout: 120, code: "five_uploads")
        let composer = app.textFields["CommandComposerField"]
        let draft = stringValue(of: composer)
        for (index, requiredExtension) in [".pdf", ".docx", ".hwp", ".hwpx", ".zip"].enumerated() {
            XCTAssertTrue(draft.contains(requiredExtension), "live_required_extension_missing=\(index)")
        }
        let returnedPaths = shellQuotedPaths(in: draft).map(shellUnquotedPath)
        XCTAssertEqual(returnedPaths.count, 5, "live_returned_path_count=\(returnedPaths.count)")
        let requiredExtensions: Set<String> = ["pdf", "docx", "hwp", "hwpx", "zip"]
        XCTAssertEqual(Set(returnedPaths.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }), requiredExtensions)
        for requiredExtension in requiredExtensions {
            XCTAssertEqual(returnedPaths.filter { URL(fileURLWithPath: $0).pathExtension.lowercased() == requiredExtension }.count, 1, "live_fixture_extension=\(requiredExtension)")
        }
        liveCleanupCommand = cleanupCommand(
            generatedImage: generatedImage,
            returnedPaths: returnedPaths,
            sentinel: cleanupSentinel
        )

        let filesButton = app.buttons["TerminalFilesButton"]
        waitForLive(filesButton, predicate: "exists == true AND hittable == true", timeout: 20, code: "artifact_button")
        filesButton.tap()
        let imageRow = app.buttons.matching(identifier: "TerminalArtifactRowImage").matching(
            NSPredicate(format: "label CONTAINS %@", "cmux-remote-qa.png")
        ).firstMatch
        waitForLive(imageRow, predicate: "exists == true AND hittable == true", timeout: 30, code: "artifact_row")
        imageRow.tap()
        let viewerImage = app.images["TerminalArtifactViewerImage"]
        waitForLive(viewerImage, predicate: "exists == true", timeout: 30, code: "viewer_image")
        retainScreenshot(named: "terminal-artifact-live-relay-matrix")
        let viewerClose = app.buttons["TerminalArtifactViewerCloseButton"]
        waitForLive(viewerClose, predicate: "exists == true AND hittable == true", timeout: 20, code: "viewer_close")
        viewerClose.tap()
        waitForLive(app.otherElements["TerminalArtifactViewerTempCount"], predicate: "value == '0'", timeout: 20, code: "viewer_temp_zero")

        confirmLiveCleanup(in: app, phase: "explicit")
    }

    private func launchArtifactApp(
        scenario: String,
        fakeRelay: Bool = true,
        koreanLargeType: Bool = false,
        attachmentScenario: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        if fakeRelay {
            app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_STALE_GATE"] = "1"
        }
        app.launchEnvironment["CMUX_SKIP_SPLASH"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_FIXTURES"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FILE_FEATURE_CACHE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["CMUX_UI_TEST_ARTIFACT_SCENARIO"] = scenario
        if let attachmentScenario {
            app.launchEnvironment["CMUX_UI_TEST_ATTACHMENT_SCENARIO"] = attachmentScenario
        }
        app.launchArguments += [
            "--cmux-skip-splash",
            "-cmux.demoMode", "NO",
            "-cmux.localNotificationsEnabled", "NO",
        ]
        if koreanLargeType {
            app.launchArguments += [
                "-AppleLanguages", "(ko)",
                "-AppleLocale", "ko_KR",
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
        releaseInitialArtifactScanIfNeeded(in: app)
    }

    private func releaseInitialArtifactScanIfNeeded(in app: XCUIApplication) {
        let gate = app.otherElements["FileFeatureContinuationGateState"]
        waitFor(gate, predicate: "value == 'blocked'", in: app)
        let release = app.buttons["FeatureFixtureReleaseStaleResponse"]
        waitFor(release, predicate: "exists == true", in: app)
        release.tap()
        waitFor(gate, predicate: "value == 'released'", in: app)
    }

    private func openFirstAvailableWorkspace(in app: XCUIApplication) {
        let workspace = app.buttons.firstMatch
        waitFor(workspace, predicate: "exists == true AND hittable == true", timeout: 30, in: app)
        workspace.tap()
        waitFor(app.otherElements["TerminalAccessoryPanel"], predicate: "exists == true", timeout: 30, in: app)
    }

    private func cleanupCommand(
        generatedImage: String,
        returnedPaths: [String],
        sentinel: String
    ) -> String {
        let suffix = String(sentinel.dropFirst("CMUX_QA_CLEANUP_".count))
        let allPaths = [generatedImage] + returnedPaths
        let quotedPaths = allPaths.map(shellQuote).joined(separator: " ")
        let absenceChecks = allPaths
            .map { "test ! -e \(shellQuote($0))" }
            .joined(separator: " && ")
        return "set -e; rm -f -- \(quotedPaths) && \(absenceChecks) && printf '\\nCMUX_QA_CLEANUP_%s\\n' \(shellQuote(suffix))"
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func confirmLiveCleanup(in app: XCUIApplication, phase: String) {
        guard let command = liveCleanupCommand,
              let sentinel = liveCleanupSentinel
        else {
            XCTFail("live_cleanup_state_missing=\(phase)")
            return
        }
        let terminal = app.scrollViews["TerminalViewport"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", sentinel),
            object: terminal
        )
        sendLiveCommand(command, in: app, code: "cleanup_send_\(phase)")
        let result = XCTWaiter.wait(for: [expectation], timeout: 30)
        XCTAssertEqual(result, .completed, "live_cleanup_confirmation=\(phase):\(result.rawValue)")
        guard result == .completed else { return }
        liveCleanupCommand = nil
        liveCleanupSentinel = nil
    }

    private func sendLiveCommand(_ command: String, in app: XCUIApplication, code: String) {
        let composer = app.textFields["CommandComposerField"]
        waitForLive(composer, predicate: "exists == true AND hittable == true", timeout: 30, code: "\(code)_composer")
        composer.tap()
        composer.typeKey("a", modifierFlags: .command)
        composer.typeText(command)
        let submit = app.buttons["CommandSubmitButton"]
        waitForLive(submit, predicate: "exists == true AND hittable == true", timeout: 20, code: "\(code)_submit")
        submit.tap()
    }

    private func sendCommand(_ command: String, in app: XCUIApplication) {
        let composer = app.textFields["CommandComposerField"]
        waitFor(composer, predicate: "exists == true AND hittable == true", timeout: 30, in: app)
        composer.tap()
        composer.typeKey("a", modifierFlags: .command)
        composer.typeText(command)
        let submit = app.buttons["CommandSubmitButton"]
        waitFor(submit, predicate: "exists == true AND hittable == true", in: app)
        submit.tap()
    }

    private func rotate(
        to orientation: UIDeviceOrientation,
        expectedState _: String,
        in app: XCUIApplication
    ) {
        XCUIDevice.shared.orientation = orientation
        XCTAssertEqual(
            XCUIDevice.shared.orientation,
            orientation,
            app.debugDescription
        )
    }

    private func dismissArtifactPresentation(in app: XCUIApplication) {
        let close = app.buttons["TerminalFilesCloseButton"]
        if close.exists, close.isHittable {
            close.tap()
        } else {
            app.swipeDown()
        }
        waitFor(app.otherElements["TerminalFilesSheet"], predicate: "exists == false", in: app)
    }

    private func waitForLive(
        _ element: XCUIElement,
        predicate format: String,
        timeout: TimeInterval,
        code: String
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: format),
            object: element
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "live_wait=\(code):\(result.rawValue)")
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

    private func assertContained(_ child: CGRect, in parent: CGRect) {
        XCTAssertGreaterThanOrEqual(child.minX, parent.minX)
        XCTAssertGreaterThanOrEqual(child.minY, parent.minY)
        XCTAssertLessThanOrEqual(child.maxX, parent.maxX)
        XCTAssertLessThanOrEqual(child.maxY, parent.maxY)
    }

    private func stringValue(of element: XCUIElement) -> String {
        if let value = element.value as? String { return value }
        return element.value.map(String.init(describing:)) ?? ""
    }

    private func normalizedInvariant(_ value: String) -> String {
        value.replacingOccurrences(of: "|idle|", with: "|sent|")
    }

    private func widthValue(named name: String, in value: String) -> CGFloat? {
        value.split(separator: "|").first { $0.hasPrefix("\(name)=") }
            .flatMap { CGFloat(Double($0.dropFirst(name.count + 1)) ?? .nan) }
            .flatMap { $0.isFinite ? $0 : nil }
    }

    private func shellQuotedPaths(in text: String) -> [String] {
        let pattern = #"'(?:[^']|'\\''?)*'"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private func shellUnquotedPath(_ quotedPath: String) -> String {
        guard quotedPath.first == "'", quotedPath.last == "'" else { return quotedPath }
        return String(quotedPath.dropFirst().dropLast())
            .replacingOccurrences(of: "'\\''", with: "'")
    }

    private func retainScreenshot(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
