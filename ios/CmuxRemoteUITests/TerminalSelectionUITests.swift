import Darwin
import ObjectiveC
import UIKit
import XCTest

final class TerminalSelectionUITests: XCTestCase {
    func testLongPressDragShowsCopyControl() throws {
        let context = try launchSelectionFixture()
        let start = context.viewport.coordinate(
            withNormalizedOffset: CGVector(dx: 0.22, dy: 0.35)
        )
        let end = context.viewport.coordinate(
            withNormalizedOffset: CGVector(dx: 0.68, dy: 0.35)
        )

        start.press(forDuration: 0.4, thenDragTo: end)

        XCTAssertTrue(
            context.copyButton.waitForExistence(timeout: 5),
            "TerminalCopySelectionButton never appeared after the 0.4-second long-press drag"
        )
    }

    func testShortVerticalSwipeScrollsWithoutShowingCopy() throws {
        let context = try launchSelectionFixture()
        let before = context.viewport.screenshot().pngRepresentation

        context.viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.25))
            .press(
                forDuration: 0.05,
                thenDragTo: context.viewport.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.12, dy: 0.75)
                )
            )

        XCTAssertTrue(context.copyButton.waitForNonExistence(timeout: 1))
        XCTAssertNotEqual(
            context.viewport.screenshot().pngRepresentation,
            before,
            "The terminal contents did not change after the vertical swipe"
        )
        XCTAssertEqual(context.viewport.frame, context.initialFrame)
    }

    func testShortHorizontalSwipeScrollsWithoutShowingCopy() throws {
        let context = try launchSelectionFixture()

        context.viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
            .press(
                forDuration: 0.05,
                thenDragTo: context.viewport.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.08, dy: 0.35)
                )
            )

        XCTAssertTrue(context.copyButton.waitForNonExistence(timeout: 1))
        let scrolledFrame = context.viewport.frame
        XCTAssertLessThan(
            scrolledFrame.minX,
            context.initialFrame.minX,
            "The terminal contents did not move horizontally"
        )
        XCTAssertEqual(scrolledFrame.minY, context.initialFrame.minY)
        XCTAssertEqual(scrolledFrame.size, context.initialFrame.size)
    }

    func testShortDiagonalAndOutsidePressNeverShowCopy() throws {
        let context = try launchSelectionFixture()

        context.viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.65))
            .press(
                forDuration: 0.05,
                thenDragTo: context.viewport.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.43, dy: 0.38)
                )
            )
        XCTAssertTrue(context.copyButton.waitForNonExistence(timeout: 1))

        context.viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(
                forDuration: 0.4,
                thenDragTo: context.viewport.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.01, dy: 0.62)
                )
            )
        XCTAssertTrue(context.copyButton.waitForNonExistence(timeout: 1))
    }

    func testReverseDragCopiesExactFixtureText() throws {
        let context = try launchSelectionFixture()
        let right = context.geometry.coordinate(
            in: context.viewport,
            row: .first,
            column: 2
        )
        let left = context.geometry.coordinate(
            in: context.viewport,
            row: .first,
            column: 0
        )

        right.press(
            forDuration: 0.4,
            thenDragTo: left,
            withVelocity: XCUIGestureVelocity(rawValue: 100),
            thenHoldForDuration: 0
        )

        XCTAssertTrue(context.copyButton.waitForExistence(timeout: 5))
        attachScreenshot(named: "fixture-reverse-selected", to: context.viewport)
        try assertCopy(context, expected: "COP", verifyExistingPasteSurface: true)
    }

    func testCancelClearsSelectionWithoutChangingClipboard() throws {
        let context = try launchSelectionFixture()
        let sentinel = "cmux-cancel-preserves-clipboard-\(UUID().uuidString)"
        UIPasteboard.general.string = sentinel
        selectExactFixtureText(in: context)

        let cancel = context.app.buttons["TerminalCancelSelectionButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(cancel.frame.width, 44)
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
        cancel.tap()

        XCTAssertTrue(context.copyButton.waitForNonExistence(timeout: 5))
        XCTAssertEqual(UIPasteboard.general.string, sentinel)
        XCTAssertTrue(context.viewport.waitForNonEmptyValue(timeout: 5))
    }

    func testPinchClearsSelection() throws {
        let context = try launchSelectionFixture()
        selectExactFixtureText(in: context)
        let selected = context.viewport.screenshot().pngRepresentation

        context.viewport.pinch(withScale: 1.35, velocity: 1)

        XCTAssertTrue(context.copyButton.waitForNonExistence(timeout: 5))
        XCTAssertNotEqual(selected, context.viewport.screenshot().pngRepresentation)
        attachScreenshot(named: "fixture-zoomed", to: context.viewport)
    }

    func testStyledBlockColorAndCopy() throws {
        let context = try launchSelectionFixture()
        attachScreenshot(named: "fixture-before", to: context.viewport)

        let image = context.viewport.screenshot().image
        let bannerGreenRun = image.maximumHorizontalRun(
            near: Fixture.greenBackground,
            tolerance: 4,
            above: Int(context.geometry.firstRowPixelY.rounded(.down))
        )
        XCTAssertGreaterThanOrEqual(
            bannerGreenRun,
            Int((24 * context.geometry.cellWidthPixels).rounded(.down)),
            "The initially visible truecolor banner was not wide enough to identify by eye"
        )
        XCTAssertGreaterThan(image.pixelCount(near: Fixture.greenBackground, tolerance: 4), 40)
        XCTAssertGreaterThan(image.pixelCount(near: Fixture.cyanForeground, tolerance: 4), 4)
        XCTAssertGreaterThan(image.pixelCount(near: Fixture.orangeForeground, tolerance: 4), 4)
        XCTAssertGreaterThan(image.pixelCount(near: Fixture.tealForeground, tolerance: 4), 4)

        selectExactFixtureText(in: context)
        attachScreenshot(named: "fixture-selected", to: context.viewport)
        try assertCopy(
            context,
            expected: Fixture.expectedCopyText,
            verifyExistingPasteSurface: true
        )
    }

    func testStyledBlockColorAndCopyInIPadLandscape() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip()
        }
        let context = try launchSelectionFixture(orientation: .landscape)
        let destinationName = "ipad"
        let minimumViewportWidthFraction: CGFloat = 0.5
        let minimumGreenPixels = 80
        let minimumForegroundPixels = 8

        XCTAssertGreaterThan(context.app.frame.width, context.app.frame.height)
        XCTAssertGreaterThan(context.viewport.frame.width, context.viewport.frame.height)
        XCTAssertGreaterThanOrEqual(
            context.viewport.frame.width,
            context.app.frame.width * minimumViewportWidthFraction
        )
        attachScreenshot(
            named: "fixture-\(destinationName)-landscape-before",
            to: context.viewport
        )

        let image = context.viewport.screenshot().image
        XCTAssertGreaterThan(
            image.pixelCount(near: Fixture.greenBackground, tolerance: 4),
            minimumGreenPixels
        )
        XCTAssertGreaterThan(
            image.pixelCount(near: Fixture.cyanForeground, tolerance: 4),
            minimumForegroundPixels
        )
        XCTAssertGreaterThan(
            image.pixelCount(near: Fixture.orangeForeground, tolerance: 4),
            minimumForegroundPixels
        )
        XCTAssertGreaterThan(
            image.pixelCount(near: Fixture.tealForeground, tolerance: 4),
            minimumForegroundPixels
        )

        selectExactFixtureText(in: context)
        attachScreenshot(
            named: "fixture-\(destinationName)-landscape-selected",
            to: context.viewport
        )
        try assertCopy(
            context,
            expected: Fixture.expectedCopyText,
            verifyExistingPasteSurface: false
        )
    }

    func testScrollThenLongPressAfterDeceleration() throws {
        let context = try launchSelectionFixture()
        let decelerationEnded = context.app.otherElements[
            "TerminalViewportDecelerationEnded"
        ]
        XCTAssertTrue(decelerationEnded.waitForExistence(timeout: 5))
        let decelerationEndExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.valueDescription == "true"
            },
            object: decelerationEnded
        )
        context.viewport.swipeUp(velocity: .fast)
        XCTAssertEqual(
            XCTWaiter.wait(for: [decelerationEndExpectation], timeout: 5),
            .completed
        )

        let start = context.viewport.coordinate(
            withNormalizedOffset: CGVector(dx: 0.22, dy: 0.35)
        )
        let end = context.viewport.coordinate(
            withNormalizedOffset: CGVector(dx: 0.68, dy: 0.35)
        )
        start.press(forDuration: 0.4, thenDragTo: end)

        XCTAssertTrue(context.copyButton.waitForExistence(timeout: 5))
    }

    func testSelectionAcrossViewportEdges() throws {
        let context = try launchSelectionFixture()
        let start = context.geometry.coordinate(
            in: context.viewport,
            row: .first,
            column: 0
        )
        let end = context.viewport.coordinate(
            withNormalizedOffset: CGVector(dx: 0.97, dy: 0.08)
        )
        start.press(forDuration: 0.4, thenDragTo: end)

        XCTAssertTrue(context.copyButton.waitForExistence(timeout: 5))
        XCTAssertTrue(context.app.buttons["TerminalCancelSelectionButton"].isHittable)
    }

    func testRotationZoomAndAccessibilitySelectionLifecycle() throws {
        let context = try launchSelectionFixture(
            contentSizeCategory: "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
        )

        let portraitViewportFrame = context.viewport.frame
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(context.app.waitForFrame(.landscape, timeout: 5))
        XCTAssertTrue(
            context.viewport.waitForFrameChange(from: portraitViewportFrame, timeout: 5)
        )

        try XCUIAccessibilityCustomActionDriver.perform(.selectAll, on: context.viewport)

        XCTAssertTrue(context.copyButton.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(context.copyButton.frame.width, 44)
        XCTAssertGreaterThanOrEqual(context.copyButton.frame.height, 44)

        let sentinel = "cmux-accessibility-copy-\(UUID().uuidString)"
        UIPasteboard.general.string = sentinel
        try XCUIAccessibilityCustomActionDriver.perform(.copy, on: context.viewport)

        XCTAssertTrue(context.copyButton.waitForNonExistence(timeout: 5))
        let copied = try readPasteboardAllowingSystemPrompt()
        XCTAssertNotEqual(copied, sentinel)
        XCTAssertEqual(copied, Fixture.expectedSelectAllText)

        let landscapeViewportFrame = context.viewport.frame
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(context.app.waitForFrame(.portrait, timeout: 5))
        XCTAssertTrue(
            context.viewport.waitForFrameChange(from: landscapeViewportFrame, timeout: 5)
        )
        XCTAssertTrue(context.viewport.waitForNonEmptyValue(timeout: 5))
    }

    private func launchSelectionFixture(
        contentSizeCategory: String? = nil,
        orientation: ObservedOrientation = .portrait
    ) throws -> SelectionFixtureContext {
        XCUIDevice.shared.orientation = orientation.deviceOrientation

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_FAKE_RELAY"] = "1"
        app.launchEnvironment["CMUX_SKIP_SPLASH"] = "1"
        app.launchArguments += [
            "--cmux-skip-splash",
            "-cmux.demoMode", "NO",
            "-cmux.localNotificationsEnabled", "NO",
        ]
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        }
        addTeardownBlock {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        app.launch()
        XCTAssertTrue(app.waitForFrame(orientation, timeout: 5), app.debugDescription)

        guard app.buttons.element(boundBy: 3).waitForExistence(timeout: 5) else {
            XCTFail(app.debugDescription)
            throw FixtureLaunchError.workspaceMissing
        }
        let minimumWorkspaceWidth = app.frame.width * 0.45
        let workspaceCards = app.buttons.allElementsBoundByIndex.filter { element in
            element.frame.width >= minimumWorkspaceWidth && element.frame.height >= 40
        }
        guard let workspaceCard = workspaceCards.min(by: { $0.frame.minY < $1.frame.minY }) else {
            XCTFail(app.debugDescription)
            throw FixtureLaunchError.workspaceMissing
        }
        workspaceCard.tap()

        let viewport = app.scrollViews["TerminalViewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(viewport.waitForRenderableFrame(timeout: 5), viewport.debugDescription)
        XCTAssertTrue(
            viewport.waitForValue(Fixture.expectedViewportValue, timeout: 5),
            viewport.valueDescription
        )
        let geometry = try XCTUnwrap(
            app.renderedFixtureGeometry(in: viewport),
            "The exact truecolor target was not visible after fixture readiness"
        )

        let copyButton = app.buttons["TerminalCopySelectionButton"]
        XCTAssertTrue(copyButton.waitForNonExistence(timeout: 1))
        return SelectionFixtureContext(
            app: app,
            viewport: viewport,
            copyButton: copyButton,
            initialFrame: viewport.frame,
            geometry: geometry
        )
    }

    private func selectExactFixtureText(in context: SelectionFixtureContext) {
        let start = context.geometry.coordinate(
            in: context.viewport,
            row: .first,
            column: 0
        )
        let end = context.geometry.coordinate(
            in: context.viewport,
            row: .last,
            column: Fixture.copyEndColumn
        )
        start.press(
            forDuration: 0.4,
            thenDragTo: end,
            withVelocity: XCUIGestureVelocity(rawValue: 100),
            thenHoldForDuration: 0
        )

        XCTAssertTrue(context.copyButton.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(context.copyButton.frame.width, 44)
        XCTAssertGreaterThanOrEqual(context.copyButton.frame.height, 44)
    }

    private func assertCopy(
        _ context: SelectionFixtureContext,
        expected: String,
        verifyExistingPasteSurface: Bool
    ) throws {
        let sentinel = "cmux-copy-sentinel-\(UUID().uuidString)"
        UIPasteboard.general.string = sentinel
        context.copyButton.tap()

        XCTAssertTrue(context.copyButton.waitForNonExistence(timeout: 5))
        let copied = try readPasteboardAllowingSystemPrompt()
        XCTAssertEqual(copied, expected)

        guard verifyExistingPasteSurface else { return }
        let paste = context.app.buttons["CommandPasteButton"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()

        let field = context.app.textFields["CommandComposerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, expected)
    }

    private func readPasteboardAllowingSystemPrompt() throws -> String {
        let state = PasteboardReadState()
        let readFinished = expectation(description: "Cross-process pasteboard read finished")
        DispatchQueue.global(qos: .userInitiated).async {
            state.finish(with: UIPasteboard.general.string)
            readFinished.fulfill()
        }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        let readOrAlert = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                state.isFinished || alert.exists
            },
            object: nil
        )
        let firstEvent: XCTWaiter.Result = XCTWaiter.wait(
            for: [readOrAlert],
            timeout: 5
        )
        XCTAssertEqual(
            firstEvent,
            XCTWaiter.Result.completed,
            "Neither the pasteboard read nor a SpringBoard alert completed: \(springboard.debugDescription)"
        )

        if !state.isFinished {
            let buttons = alert.buttons.allElementsBoundByIndex
            let positiveCandidates = buttons.filter { candidate in
                guard !candidate.label.isEmpty else { return false }
                return buttons.contains { other in
                    other.label.count > candidate.label.count
                        && other.label.contains(candidate.label)
                }
            }
            guard positiveCandidates.count == 1,
                  let allowPaste = positiveCandidates.first
            else {
                XCTFail("Paste alert buttons were not unambiguous: \(alert.debugDescription)")
                throw PasteboardReadError.positiveActionUnavailable(
                    buttonLabels: buttons.map(\.label)
                )
            }
            allowPaste.tap()
        }

        let readResult = XCTWaiter.wait(for: [readFinished], timeout: 5)
        XCTAssertEqual(readResult, .completed, "Pasteboard read did not finish")
        guard readResult == .completed else { throw PasteboardReadError.readTimedOut }
        return try XCTUnwrap(state.value)
    }

    private func attachScreenshot(named name: String, to element: XCUIElement) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct SelectionFixtureContext {
    let app: XCUIApplication
    let viewport: XCUIElement
    let copyButton: XCUIElement
    let initialFrame: CGRect
    let geometry: RenderedFixtureGeometry
}

private enum Fixture {
    static let copyEndColumn = 7
    static let expectedCopyText = "COPY A  \n한글界\nCOPY B  "
    static let expectedViewportValue = "$ cmux palette --selection\nTruecolor, Unicode, and copy\nBOLD TRUECOLOR\nUNDERLINE OLIVE"
    static let expectedSelectAllText: String = {
        var rows = (0..<72).map { index in
            String(format: "render pass %02d · scroll lane", index)
        }
        rows[0] = "$ cmux palette --selection"
        rows[1] = "Truecolor, Unicode, and copy"
        rows[2] = ""
        rows[3] = "BOLD TRUECOLOR"
        rows[4] = "UNDERLINE OLIVE"
        rows[5] = "                "
        rows[6] = "e\u{301} · 한글界"
        rows[7] = "left  middle  right   "
        rows[8] = ""
        rows[9] = "Scroll lanes continue below"
        rows[10] = ""
        rows[11] = ""

        let wideRule = String(repeating: "0123456789", count: 15)
        for index in 36...56 {
            rows[index] = String(format: "wide canvas %02d · %@", index, wideRule)
        }

        rows[57] = "Palette inspection complete"
        rows[60] = "e\u{301} · 한글界"
        rows[61] = "                "
        rows[62] = "left  middle  right   "
        rows[63] = ""
        rows[64] = "e\u{301} · 한글界"
        rows[65] = "                "
        rows[66] = "left  middle  right   "
        rows[67] = ""
        rows[68] = " ┌ TRUECOLOR COPY FIXTURE ┐ "
        rows[69] = "COPY A  "
        rows[70] = "한글界"
        rows[71] = "COPY B  "
        return rows.joined(separator: "\n")
    }()

    static let greenBackground = RGB(red: 40, green: 50, blue: 40)
    static let cyanForeground = RGB(red: 125, green: 207, blue: 255)
    static let orangeForeground = RGB(red: 255, green: 158, blue: 100)
    static let tealForeground = RGB(red: 26, green: 188, blue: 156)
}

private enum FixtureLaunchError: Error {
    case workspaceMissing
}

private enum PasteboardReadError: Error {
    case positiveActionUnavailable(buttonLabels: [String])
    case readTimedOut
}

private final class PasteboardReadState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?
    private var finished = false

    var isFinished: Bool {
        lock.withLock { finished }
    }

    var value: String? {
        lock.withLock { storedValue }
    }

    func finish(with value: String?) {
        lock.withLock {
            storedValue = value
            finished = true
        }
    }
}

private enum ObservedOrientation {
    case portrait
    case landscape

    var deviceOrientation: UIDeviceOrientation {
        switch self {
        case .portrait: .portrait
        case .landscape: .landscapeLeft
        }
    }

    func matches(_ frame: CGRect) -> Bool {
        guard frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0
        else { return false }
        switch self {
        case .portrait: return frame.height > frame.width
        case .landscape: return frame.width > frame.height
        }
    }
}

private struct RenderedFixtureGeometry {
    enum Row {
        case first
        case middle
        case last
    }

    let cropOriginInViewport: CGPoint
    let pixelsPerPointX: CGFloat
    let pixelsPerPointY: CGFloat
    let leftPixel: CGFloat
    let cellWidthPixels: CGFloat
    let firstRowPixelY: CGFloat
    let middleRowPixelY: CGFloat
    let lastRowPixelY: CGFloat

    func coordinate(
        in viewport: XCUIElement,
        row: Row,
        column: Int
    ) -> XCUICoordinate {
        let rowPixelY: CGFloat
        switch row {
        case .first: rowPixelY = firstRowPixelY
        case .middle: rowPixelY = middleRowPixelY
        case .last: rowPixelY = lastRowPixelY
        }
        let pixelX = leftPixel + (CGFloat(column) + 0.5) * cellWidthPixels
        let viewportPoint = CGPoint(
            x: cropOriginInViewport.x + pixelX / pixelsPerPointX,
            y: cropOriginInViewport.y + rowPixelY / pixelsPerPointY
        )
        return viewport.coordinate(withNormalizedOffset: CGVector(
            dx: viewportPoint.x / viewport.frame.width,
            dy: viewportPoint.y / viewport.frame.height
        ))
    }
}

private struct RGB {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

private struct PixelRaster {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func matches(x: Int, y: Int, color: RGB, tolerance: UInt8) -> Bool {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return false }
        let index = (y * width + x) * 4
        let tolerance = Int(tolerance)
        return abs(Int(bytes[index]) - Int(color.red)) <= tolerance
            && abs(Int(bytes[index + 1]) - Int(color.green)) <= tolerance
            && abs(Int(bytes[index + 2]) - Int(color.blue)) <= tolerance
    }

    func bounds(near color: RGB, tolerance: UInt8) -> CGRect? {
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where matches(x: x, y: y, color: color, tolerance: tolerance) {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }

    func verticalBands(
        near color: RGB,
        background: RGB,
        tolerance: UInt8,
        pixelsPerPoint: CGFloat
    ) -> [CGRect] {
        let searchWidth = min(width, 512)
        var matchedRows: [(y: Int, minX: Int, maxX: Int)] = []
        for y in 0..<height {
            let xs = (0..<searchWidth).filter {
                matches(x: $0, y: y, color: color, tolerance: tolerance)
            }
            guard let minX = xs.min(), let maxX = xs.max() else { continue }
            let nearbyBackground = (max(0, minX - 80)...min(searchWidth - 1, maxX + 80))
                .contains { matches(x: $0, y: y, color: background, tolerance: tolerance) }
            if nearbyBackground {
                matchedRows.append((y, minX, maxX))
            }
        }

        let maximumBlankRowGap = Int(ceil(3 * pixelsPerPoint))
        var bands: [CGRect] = []
        for row in matchedRows {
            let rowBounds = CGRect(
                x: row.minX,
                y: row.y,
                width: row.maxX - row.minX + 1,
                height: 1
            )
            if let last = bands.indices.last {
                let blankRowGap = row.y - Int(bands[last].maxY) - 1
                let horizontalOverlap = bands[last].minX <= rowBounds.maxX
                    && rowBounds.minX <= bands[last].maxX
                if blankRowGap <= maximumBlankRowGap, horizontalOverlap {
                    bands[last] = bands[last].union(rowBounds)
                    continue
                }
            }
            bands.append(rowBounds)
        }
        return bands
    }

    func greenFixtureBlocks(
        color: RGB,
        tolerance: UInt8,
        pixelsPerPoint: CGFloat
    ) -> [CGRect] {
        let searchWidth = min(width, 512)
        var greenRows: [(y: Int, minX: Int, maxX: Int)] = []
        for y in 0..<height {
            let xs = (0..<searchWidth).filter {
                matches(x: $0, y: y, color: color, tolerance: tolerance)
            }
            if let minX = xs.min(), let maxX = xs.max() {
                greenRows.append((y, minX, maxX))
            }
        }

        let maximumBlankRowGap = Int(ceil(3 * pixelsPerPoint))
        var blocks: [CGRect] = []
        for row in greenRows {
            let rowBounds = CGRect(
                x: row.minX,
                y: row.y,
                width: row.maxX - row.minX + 1,
                height: 1
            )
            if let last = blocks.indices.last {
                let blankRowGap = row.y - Int(blocks[last].maxY) - 1
                let horizontalOverlap = blocks[last].minX <= rowBounds.maxX
                    && rowBounds.minX <= blocks[last].maxX
                if blankRowGap <= maximumBlankRowGap, horizontalOverlap {
                    blocks[last] = blocks[last].union(rowBounds)
                    continue
                }
            }
            blocks.append(rowBounds)
        }
        return blocks
    }

    func foregroundBackingEvidence(
        foreground: RGB,
        background: RGB,
        tolerance: UInt8,
        in band: CGRect
    ) -> (sample: CGPoint, backgroundBounds: ClosedRange<Int>)? {
        var sample: CGPoint?
        var backgroundMinX = width
        var backgroundMaxX = -1
        let lowerY = max(0, Int(floor(band.minY)))
        let upperY = min(height - 1, Int(ceil(band.maxY)) - 1)
        let lowerX = max(0, Int(floor(band.minX)))
        let upperX = min(width - 1, Int(ceil(band.maxX)) - 1)
        for y in lowerY...upperY {
            for x in lowerX...upperX
            where matches(x: x, y: y, color: foreground, tolerance: tolerance) {
                let nearbyBackground = (max(0, x - 80)...min(width - 1, x + 80)).filter {
                    matches(x: $0, y: y, color: background, tolerance: tolerance)
                }
                guard let rowMinX = nearbyBackground.min(),
                      let rowMaxX = nearbyBackground.max()
                else { continue }
                if sample == nil { sample = CGPoint(x: x, y: y) }
                backgroundMinX = min(backgroundMinX, rowMinX)
                backgroundMaxX = max(backgroundMaxX, rowMaxX)
            }
        }
        guard let sample, backgroundMaxX >= backgroundMinX else { return nil }
        return (sample, backgroundMinX...backgroundMaxX)
    }

    func coolForegroundBounds(
        around targetY: Int,
        radius: Int,
        xRange: ClosedRange<Int>,
        background: RGB
    ) -> CGRect? {
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        let lowerY = max(0, targetY - radius)
        let upperY = min(height - 1, targetY + radius)
        let lowerX = max(0, xRange.lowerBound)
        let upperX = min(width - 1, xRange.upperBound)
        for y in lowerY...upperY {
            for x in lowerX...upperX {
                let index = (y * width + x) * 4
                let red = Int(bytes[index])
                let green = Int(bytes[index + 1])
                let blue = Int(bytes[index + 2])
                let saturation = max(red, green, blue) - min(red, green, blue)
                let backgroundDistance = max(
                    abs(red - Int(background.red)),
                    abs(green - Int(background.green)),
                    abs(blue - Int(background.blue))
                )
                guard blue > red + 40,
                      green > red + 20,
                      blue >= green,
                      saturation >= 50,
                      backgroundDistance >= 50
                else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }

    func horizontalBounds(
        near color: RGB,
        tolerance: UInt8,
        around targetY: Int,
        radius: Int,
        xRange: ClosedRange<Int>
    ) -> ClosedRange<Int>? {
        var minX = width
        var maxX = -1
        let lowerY = max(0, targetY - radius)
        let upperY = min(height - 1, targetY + radius)
        let lowerX = max(0, xRange.lowerBound)
        let upperX = min(width - 1, xRange.upperBound)
        for y in lowerY...upperY {
            for x in lowerX...upperX
            where matches(x: x, y: y, color: color, tolerance: tolerance) {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        guard maxX >= minX else { return nil }
        return minX...maxX
    }

    func maximumHorizontalRun(
        near color: RGB,
        tolerance: UInt8,
        above upperY: Int
    ) -> Int {
        let lastY = min(max(upperY - 1, 0), height - 1)
        var maximum = 0
        for y in 0...lastY {
            var current = 0
            for x in 0..<width {
                if matches(x: x, y: y, color: color, tolerance: tolerance) {
                    current += 1
                    maximum = max(maximum, current)
                } else {
                    current = 0
                }
            }
        }
        return maximum
    }
}

private struct VisibleScreenshotCrop {
    let image: UIImage
    let originInViewport: CGPoint
    let pixelsPerPointX: CGFloat
    let pixelsPerPointY: CGFloat
}

private extension UIImage {
    func normalizedNativeRaster(
        matching appFrame: CGRect,
        deviceOrientation: UIDeviceOrientation
    ) -> UIImage? {
        guard let cgImage else { return nil }
        let rawIsLandscape = cgImage.width > cgImage.height
        let appIsLandscape = appFrame.width > appFrame.height
        if imageOrientation == .up, rawIsLandscape == appIsLandscape {
            return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        }

        let rasterSize = rawIsLandscape == appIsLandscape
            ? CGSize(width: cgImage.width, height: cgImage.height)
            : CGSize(width: cgImage.height, height: cgImage.width)
        let rawImage = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: rasterSize, format: format).image { renderer in
            let context = renderer.cgContext
            switch (imageOrientation, deviceOrientation) {
            case (.left, .landscapeLeft):
                context.translateBy(x: 0, y: rasterSize.height)
                context.rotate(by: -.pi / 2)
            case (.right, .landscapeRight):
                context.translateBy(x: rasterSize.width, y: 0)
                context.rotate(by: .pi / 2)
            default:
                return
            }
            rawImage.draw(in: CGRect(
                x: 0,
                y: 0,
                width: cgImage.width,
                height: cgImage.height
            ))
        }
    }

    func renderedFixtureGeometry(
        cropOriginInViewport: CGPoint,
        pixelsPerPointX: CGFloat,
        pixelsPerPointY: CGFloat
    ) -> RenderedFixtureGeometry? {
        guard let raster = pixelRaster() else { return nil }
        let firstBands = raster.verticalBands(
            near: Fixture.cyanForeground,
            background: Fixture.greenBackground,
            tolerance: 4,
            pixelsPerPoint: pixelsPerPointY
        )
        let middleBands = raster.verticalBands(
            near: Fixture.orangeForeground,
            background: Fixture.greenBackground,
            tolerance: 4,
            pixelsPerPoint: pixelsPerPointY
        )
        let lastBands = raster.verticalBands(
            near: Fixture.tealForeground,
            background: Fixture.greenBackground,
            tolerance: 4,
            pixelsPerPoint: pixelsPerPointY
        )
        let triplets = firstBands.flatMap { first in
            middleBands.flatMap { middle in
                lastBands.compactMap { last -> (CGRect, CGRect, CGRect, CGFloat)? in
                    let firstGap = middle.midY - first.midY
                    let secondGap = last.midY - middle.midY
                    guard firstGap > 4, firstGap < 100,
                          secondGap > 4, secondGap < 100,
                          abs(firstGap - secondGap) < 16,
                          abs(first.midX - middle.midX) < 200,
                          abs(middle.midX - last.midX) < 200
                    else { return nil }
                    return (first, middle, last, abs(firstGap - secondGap))
                }
            }
        }
        let rows: (first: CGRect, middle: CGRect, last: CGRect)
        if let direct = triplets.min(by: { $0.3 < $1.3 }) {
            rows = (direct.0, direct.1, direct.2)
        } else {
            guard middleBands.count == 1, lastBands.count == 1 else {
                return nil
            }
            let middle = middleBands[0]
            let last = lastBands[0]
            let rowStep = last.midY - middle.midY
            guard rowStep > 4, rowStep < 100,
                  abs(middle.midX - last.midX) < 200
            else {
                return nil
            }

            guard let middleEvidence = raster.foregroundBackingEvidence(
                foreground: Fixture.orangeForeground,
                background: Fixture.greenBackground,
                tolerance: 4,
                in: middle
            ), let lastEvidence = raster.foregroundBackingEvidence(
                foreground: Fixture.tealForeground,
                background: Fixture.greenBackground,
                tolerance: 4,
                in: last
            ) else {
                return nil
            }
            let middleGreen = middleEvidence.backgroundBounds
            let lastGreen = lastEvidence.backgroundBounds
            let foregroundMargin = max(1, Int(ceil(0.5 * pixelsPerPointX)))
            let leftEdgeTolerance = max(1, Int(ceil(pixelsPerPointX)))
            let middleForeground = Int(floor(middle.minX))...Int(ceil(middle.maxX) - 1)
            let lastForeground = Int(floor(last.minX))...Int(ceil(last.maxX) - 1)
            let middleIsContained = middleGreen.lowerBound
                    <= middleForeground.lowerBound - foregroundMargin
                && middleGreen.upperBound
                    >= middleForeground.upperBound + foregroundMargin
            let lastIsContained = lastGreen.lowerBound
                    <= lastForeground.lowerBound - foregroundMargin
                && lastGreen.upperBound
                    >= lastForeground.upperBound + foregroundMargin
            guard middleIsContained, lastIsContained,
                  abs(middleGreen.lowerBound - lastGreen.lowerBound) <= leftEdgeTolerance
            else {
                return nil
            }

            let greenBlocks = raster.greenFixtureBlocks(
                color: Fixture.greenBackground,
                tolerance: 4,
                pixelsPerPoint: pixelsPerPointY
            )
            let candidateBlocks = greenBlocks.compactMap { block -> (CGRect, CGRect, CGRect, CGRect, CGPoint)? in
                guard block.contains(middleEvidence.sample),
                      block.contains(lastEvidence.sample),
                      block.minX <= CGFloat(min(middleGreen.lowerBound, lastGreen.lowerBound)),
                      block.maxX >= CGFloat(max(middleGreen.upperBound, lastGreen.upperBound)),
                      block.height >= 3 * pixelsPerPointY
                else { return nil }
                let rowHeight = block.height / 3
                let firstRow = CGRect(
                    x: block.minX,
                    y: block.minY,
                    width: block.width,
                    height: rowHeight
                )
                let secondRow = CGRect(
                    x: block.minX,
                    y: block.minY + rowHeight,
                    width: block.width,
                    height: rowHeight
                )
                let thirdRow = CGRect(
                    x: block.minX,
                    y: block.minY + 2 * rowHeight,
                    width: block.width,
                    height: block.height - 2 * rowHeight
                )
                guard secondRow.contains(middleEvidence.sample),
                      thirdRow.contains(lastEvidence.sample)
                else { return nil }

                if let cyanEvidence = firstBands.compactMap({ band in
                    raster.foregroundBackingEvidence(
                        foreground: Fixture.cyanForeground,
                        background: Fixture.greenBackground,
                        tolerance: 4,
                        in: band
                    )
                }).first(where: { firstRow.contains($0.sample) }) {
                    return (block, firstRow, secondRow, thirdRow, cyanEvidence.sample)
                }
                guard let coolBounds = raster.coolForegroundBounds(
                    around: Int(firstRow.midY.rounded()),
                    radius: Int(ceil(rowHeight / 2)),
                    xRange: Int(firstRow.minX)...Int(firstRow.maxX - 1),
                    background: Fixture.greenBackground
                ), firstRow.contains(CGPoint(x: coolBounds.midX, y: coolBounds.midY))
                else { return nil }
                return (block, firstRow, secondRow, thirdRow, CGPoint(
                    x: coolBounds.midX,
                    y: firstRow.midY
                ))
            }
            guard candidateBlocks.count == 1, let fixture = candidateBlocks.first else {
                return nil
            }
            rows = (
                CGRect(x: fixture.4.x, y: fixture.1.midY, width: 1, height: 1),
                CGRect(x: middle.midX, y: fixture.2.midY, width: 1, height: 1),
                CGRect(x: last.midX, y: fixture.3.midY, width: 1, height: 1)
            )
        }
        let first = rows.first
        let middle = rows.middle
        let last = rows.last
        guard let greenBounds = raster.horizontalBounds(
            near: Fixture.greenBackground,
            tolerance: 4,
            around: Int(first.midY.rounded()),
            radius: 1,
            xRange: (Int(first.minX) - 100)...(Int(first.maxX) + 200)
        ) else { return nil }

        let backgroundWidth = CGFloat(greenBounds.upperBound - greenBounds.lowerBound + 1)
        let cellWidth = backgroundWidth / 8
        guard cellWidth > 1 else { return nil }
        return RenderedFixtureGeometry(
            cropOriginInViewport: cropOriginInViewport,
            pixelsPerPointX: pixelsPerPointX,
            pixelsPerPointY: pixelsPerPointY,
            leftPixel: CGFloat(greenBounds.lowerBound),
            cellWidthPixels: cellWidth,
            firstRowPixelY: first.midY,
            middleRowPixelY: middle.midY,
            lastRowPixelY: last.midY
        )
    }

    func pixelCount(near expected: RGB, tolerance: UInt8) -> Int {
        guard let raster = pixelRaster() else { return 0 }
        return (0..<raster.height).reduce(into: 0) { count, y in
            for x in 0..<raster.width where raster.matches(
                x: x,
                y: y,
                color: expected,
                tolerance: tolerance
            ) {
                count += 1
            }
        }
    }

    func maximumHorizontalRun(
        near expected: RGB,
        tolerance: UInt8,
        above upperY: Int
    ) -> Int {
        guard let raster = pixelRaster() else { return 0 }
        return raster.maximumHorizontalRun(
            near: expected,
            tolerance: tolerance,
            above: upperY
        )
    }

    private func pixelRaster() -> PixelRaster? {
        guard let cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return PixelRaster(width: width, height: height, bytes: pixels)
    }
}

private enum XCUIAccessibilityCustomActionDriver {
    enum SemanticAction {
        case selectAll
        case copy

        var productionName: String {
            switch self {
            case .selectAll: "Select all terminal text"
            case .copy: "Copy terminal selection"
            }
        }
    }

    private static let customActionsSymbol = "XC_kAXXCAttributeCustomActions"
    private static let customActionIdentifierKey = "CustomActionIdentifier"
    private static let customActionNameKey = "CustomActionName"
    private static let defaultSymbolScope = UnsafeMutableRawPointer(bitPattern: -2)

    static func actions(for element: XCUIElement) throws -> [NSDictionary] {
        guard let symbol = dlsym(defaultSymbolScope, customActionsSymbol),
              let attributePointer = symbol.assumingMemoryBound(
                to: UnsafeRawPointer?.self
              ).pointee
        else { throw AccessibilityActionError.customActionsAttributeUnavailable }
        let attribute = Unmanaged<AnyObject>.fromOpaque(attributePointer).takeUnretainedValue()
        let selector = NSSelectorFromString("valueForAccessibilityAttribute:error:")
        guard element.responds(to: selector),
              let result = element.perform(selector, with: attribute, with: nil)?.takeUnretainedValue(),
              let array = result as? NSArray
        else { throw AccessibilityActionError.customActionsUnavailable }
        return array.compactMap { $0 as? NSDictionary }
    }

    static func perform(_ semanticAction: SemanticAction, on element: XCUIElement) throws {
        let availableActions = try actions(for: element)
        guard let customAction = availableActions.first(where: {
            $0[customActionNameKey] as? String == semanticAction.productionName
        }) else {
            let availableNames = availableActions.compactMap {
                $0[customActionNameKey] as? String
            }
            throw AccessibilityActionError.namedActionUnavailable(
                expected: semanticAction.productionName,
                available: availableNames
            )
        }
        guard let identifier = customAction[customActionIdentifierKey] as AnyObject? else {
            throw AccessibilityActionError.identifierMissing
        }

        let underlyingSelector = NSSelectorFromString("performWithUnderlyingElement:")
        var underlyingElement: AnyObject?
        let capture: @convention(block) (AnyObject) -> Void = { underlyingElement = $0 }
        guard element.responds(to: underlyingSelector) else {
            throw AccessibilityActionError.underlyingElementUnavailable
        }
        element.perform(underlyingSelector, with: capture)
        guard let underlyingElement else {
            throw AccessibilityActionError.underlyingElementUnavailable
        }

        guard let wrapperType = NSClassFromString("XCAccessibilityElement") as? NSObject.Type,
              let wrapped = wrapperType.perform(
                NSSelectorFromString("elementWithAXUIElement:"),
                with: underlyingElement
              )?.takeUnretainedValue(),
              let actionType = NSClassFromString("XCUIAccessibilityAction"),
              let actionInstance = class_createInstance(actionType, 0),
              let initializer = class_getInstanceMethod(
                actionType,
                NSSelectorFromString("initWithAXAction:")
              )
        else { throw AccessibilityActionError.runtimeTypeUnavailable }

        typealias InitializeAction = @convention(c) (
            AnyObject,
            Selector,
            Int32
        ) -> Unmanaged<AnyObject>
        let initialize = unsafeBitCast(
            method_getImplementation(initializer),
            to: InitializeAction.self
        )
        let action = initialize(
            actionInstance as AnyObject,
            NSSelectorFromString("initWithAXAction:"),
            0x7e5
        ).takeUnretainedValue()

        guard let interface = XCUIDevice.shared.value(
            forKey: "accessibilityInterface"
        ) as AnyObject?,
            let interfaceType = object_getClass(interface),
            let performMethod = class_getInstanceMethod(
                interfaceType,
                NSSelectorFromString("performAction:onElement:value:error:")
            )
        else { throw AccessibilityActionError.interfaceUnavailable }

        typealias PerformAction = @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            AnyObject,
            AnyObject,
            UnsafeMutablePointer<NSError?>?
        ) -> Bool
        let perform = unsafeBitCast(
            method_getImplementation(performMethod),
            to: PerformAction.self
        )
        var error: NSError?
        let succeeded = perform(
            interface,
            NSSelectorFromString("performAction:onElement:value:error:"),
            action,
            wrapped,
            identifier,
            &error
        )
        if let error { throw error }
        guard succeeded else { throw AccessibilityActionError.actionRejected }
    }
}

private enum AccessibilityActionError: Error {
    case customActionsAttributeUnavailable
    case customActionsUnavailable
    case namedActionUnavailable(expected: String, available: [String])
    case identifierMissing
    case underlyingElementUnavailable
    case runtimeTypeUnavailable
    case interfaceUnavailable
    case actionRejected
}

private extension XCUIApplication {
    func visibleScreenshotCrop(for viewport: XCUIElement) -> VisibleScreenshotCrop? {
        let appFrame = frame
        let viewportFrame = viewport.frame
        let visibleFrame = viewportFrame.intersection(appFrame)
        guard !visibleFrame.isNull, !visibleFrame.isEmpty,
              appFrame.width > 0, appFrame.height > 0
        else { return nil }

        let rawScreenshot = screenshot().image
        let deviceOrientation = XCUIDevice.shared.orientation
        guard let screenshot = rawScreenshot.normalizedNativeRaster(
            matching: appFrame,
            deviceOrientation: deviceOrientation
        ), let cgImage = screenshot.cgImage
        else { return nil }
        let pixelsPerPointX = CGFloat(cgImage.width) / appFrame.width
        let pixelsPerPointY = CGFloat(cgImage.height) / appFrame.height
        let scaleTolerance = CGFloat.ulpOfOne * max(pixelsPerPointX, pixelsPerPointY) * 8
        guard pixelsPerPointX.isFinite, pixelsPerPointX > 0,
              pixelsPerPointY.isFinite, pixelsPerPointY > 0,
              abs(pixelsPerPointX - pixelsPerPointY) <= scaleTolerance
        else { return nil }

        let rawPixelFrame = CGRect(
            x: (visibleFrame.minX - appFrame.minX) * pixelsPerPointX,
            y: (visibleFrame.minY - appFrame.minY) * pixelsPerPointY,
            width: visibleFrame.width * pixelsPerPointX,
            height: visibleFrame.height * pixelsPerPointY
        )
        let imageBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let pixelFrame = CGRect(
            x: floor(rawPixelFrame.minX),
            y: floor(rawPixelFrame.minY),
            width: ceil(rawPixelFrame.maxX) - floor(rawPixelFrame.minX),
            height: ceil(rawPixelFrame.maxY) - floor(rawPixelFrame.minY)
        ).intersection(imageBounds)
        guard !pixelFrame.isNull, !pixelFrame.isEmpty,
              let croppedImage = cgImage.cropping(to: pixelFrame)
        else { return nil }

        let croppedScreenshot = UIImage(cgImage: croppedImage)
        let cropOriginInApp = CGPoint(
            x: appFrame.minX + pixelFrame.minX / pixelsPerPointX,
            y: appFrame.minY + pixelFrame.minY / pixelsPerPointY
        )
        return VisibleScreenshotCrop(
            image: croppedScreenshot,
            originInViewport: CGPoint(
                x: cropOriginInApp.x - viewportFrame.minX,
                y: cropOriginInApp.y - viewportFrame.minY
            ),
            pixelsPerPointX: pixelsPerPointX,
            pixelsPerPointY: pixelsPerPointY
        )
    }

    func renderedFixtureGeometry(
        in viewport: XCUIElement
    ) -> RenderedFixtureGeometry? {
        guard let crop = visibleScreenshotCrop(for: viewport) else { return nil }
        return crop.image.renderedFixtureGeometry(
            cropOriginInViewport: crop.originInViewport,
            pixelsPerPointX: crop.pixelsPerPointX,
            pixelsPerPointY: crop.pixelsPerPointY
        )
    }

}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        if !exists { return true }
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForNonEmptyValue(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return !element.valueDescription.isEmpty
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForValue(_ expected: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return element.valueDescription == expected
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForRenderableFrame(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  element.exists,
                  element.isHittable
            else { return false }
            let frame = element.frame
            return frame.width.isFinite && frame.height.isFinite
                && frame.width > 0 && frame.height > 0
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForFrameChange(from previous: CGRect, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  element.exists,
                  element.isHittable
            else { return false }
            return element.frame != previous
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForFrame(_ orientation: ObservedOrientation, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  element.exists,
                  element.isHittable
            else { return false }
            return orientation.matches(element.frame)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    var valueDescription: String {
        if let value = value as? String { return value }
        return label
    }
}
