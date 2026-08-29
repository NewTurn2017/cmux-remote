import CoreGraphics
import SharedKit
import SwiftUI
import Testing
import UIKit
@testable import CmuxRemote

@Suite("TerminalViewTests")
@MainActor
struct TerminalViewTests {
    @Test func layoutPolicyPreservesTerminalDensityAndBottomPadding() {
        #expect(TerminalLayoutPolicy.defaultFontSize(isPad: true) == 11)
        #expect(TerminalLayoutPolicy.defaultFontSize(isPad: false) == 8)
        #expect(TerminalView.bottomScrollPaddingRows == 5)
        #expect(TerminalView.bottomScrollPadding(lineHeight: 10) == 50)
        #expect(TerminalSelectionActionControls.controlSize == CGSize(width: 44, height: 44))
        #expect(TerminalSelectionActionControls.boundedSymbolSize(10) == 15)
        #expect(TerminalSelectionActionControls.boundedSymbolSize(18) == 18)
        #expect(TerminalSelectionActionControls.boundedSymbolSize(40) == 22)
    }

    @Test func gesturePolicyLeavesScrollingEnabledUntilSelectionRecognition() {
        #expect(TerminalSelectionGesturePolicy.minimumPressDuration == 0.4)
        #expect(TerminalSelectionGesturePolicy.maximumPressDistance == 12)
        #expect(TerminalSelectionGesturePolicy.minimumDragDistance == 0)
        #expect(TerminalSelectionGesturePolicy.allowsScrolling(during: .idle))
        #expect(!TerminalSelectionGesturePolicy.allowsScrolling(during: .selecting))
        #expect(TerminalSelectionGesturePolicy.allowsScrolling(during: .selected))
    }

    @Test func handleGeometryUsesExactSingleLineCJKAndMultilineBoundaries() throws {
        let layout = TerminalGridLayout(cellWidth: 8, lineHeight: 16)

        let singleLine = try #require(TerminalSelection(
            snapshot: snapshot(["ABC"]),
            anchor: TerminalGridPosition(row: 0, column: 1),
            focus: TerminalGridPosition(row: 0, column: 1)
        ))
        #expect(TerminalSelectionOverlayGeometry.handleCenter(
            for: .start,
            selection: singleLine,
            layout: layout
        ) == CGPoint(x: 24, y: 16))
        #expect(TerminalSelectionOverlayGeometry.handleCenter(
            for: .end,
            selection: singleLine,
            layout: layout
        ) == CGPoint(x: 32, y: 16))

        let cjk = try #require(TerminalSelection(
            snapshot: snapshot(["A한B"]),
            anchor: TerminalGridPosition(row: 0, column: 1),
            focus: TerminalGridPosition(row: 0, column: 1)
        ))
        #expect(TerminalSelectionOverlayGeometry.handleCenter(
            for: .start,
            selection: cjk,
            layout: layout
        ) == CGPoint(x: 24, y: 16))
        #expect(TerminalSelectionOverlayGeometry.handleCenter(
            for: .end,
            selection: cjk,
            layout: layout
        ) == CGPoint(x: 40, y: 16))

        let multiline = try #require(TerminalSelection(
            snapshot: snapshot(["AB", "CD"]),
            anchor: TerminalGridPosition(row: 0, column: 1),
            focus: TerminalGridPosition(row: 1, column: 0)
        ))
        #expect(TerminalSelectionOverlayGeometry.handleCenter(
            for: .start,
            selection: multiline,
            layout: layout
        ) == CGPoint(x: 24, y: 16))
        #expect(TerminalSelectionOverlayGeometry.handleCenter(
            for: .end,
            selection: multiline,
            layout: layout
        ) == CGPoint(x: 24, y: 32))
    }

    @Test func handlePolicyUsesCompactRingsAndClampedFortyFourPointHitFrames() {
        let visibleRect = CGRect(x: 100, y: 50, width: 120, height: 80)
        let start = CGPoint(x: 100, y: 50)
        let end = CGPoint(x: 220, y: 130)

        #expect(TerminalSelectionGesturePolicy.visibleHandleDiameter == 12)
        #expect(TerminalSelectionGesturePolicy.handleHitDiameter == 44)
        #expect(TerminalSelectionGesturePolicy.boundedHitFrame(
            for: start,
            in: visibleRect
        ) == CGRect(x: 100, y: 50, width: 44, height: 44))
        #expect(TerminalSelectionGesturePolicy.boundedHitFrame(
            for: end,
            in: visibleRect
        ) == CGRect(x: 176, y: 86, width: 44, height: 44))
        #expect(TerminalSelectionGesturePolicy.boundary(
            at: CGPoint(x: 100, y: 50),
            startCenter: start,
            endCenter: end,
            in: visibleRect
        ) == .start)
        #expect(TerminalSelectionGesturePolicy.boundary(
            at: CGPoint(x: 219.99, y: 129.99),
            startCenter: start,
            endCenter: end,
            in: visibleRect
        ) == .end)

        let overlappingStart = CGPoint(x: 110, y: 90)
        let overlappingEnd = CGPoint(x: 120, y: 90)
        #expect(TerminalSelectionGesturePolicy.boundary(
            at: CGPoint(x: 117, y: 90),
            startCenter: overlappingStart,
            endCenter: overlappingEnd,
            in: visibleRect
        ) == .end)
    }

    @Test func fullyOffscreenHandleRingsProduceNoHitFramesOrBoundaries() {
        let visibleRect = CGRect(x: 100, y: 50, width: 120, height: 80)
        let fullyOffscreenCenters = [
            CGPoint(x: 93, y: 90),
            CGPoint(x: 227, y: 90),
            CGPoint(x: 160, y: 43),
            CGPoint(x: 160, y: 137),
        ]
        let otherOffscreenCenter = CGPoint(x: -1_000, y: -1_000)

        for center in fullyOffscreenCenters {
            #expect(TerminalSelectionGesturePolicy.boundedHitFrame(
                for: center,
                in: visibleRect
            ) == nil)
            #expect(TerminalSelectionGesturePolicy.boundary(
                at: CGPoint(x: visibleRect.midX, y: visibleRect.midY),
                startCenter: center,
                endCenter: otherOffscreenCenter,
                in: visibleRect
            ) == nil)
        }
    }

    @Test func partiallyVisibleHandleRingsReceiveClampedHitFrames() {
        let visibleRect = CGRect(x: 100, y: 50, width: 120, height: 80)
        let cases: [(CGPoint, CGRect)] = [
            (CGPoint(x: 95, y: 90), CGRect(x: 100, y: 68, width: 44, height: 44)),
            (CGPoint(x: 225, y: 90), CGRect(x: 176, y: 68, width: 44, height: 44)),
            (CGPoint(x: 160, y: 45), CGRect(x: 138, y: 50, width: 44, height: 44)),
            (CGPoint(x: 160, y: 135), CGRect(x: 138, y: 86, width: 44, height: 44)),
        ]
        let otherOffscreenCenter = CGPoint(x: -1_000, y: -1_000)

        for (center, expectedFrame) in cases {
            #expect(TerminalSelectionGesturePolicy.boundedHitFrame(
                for: center,
                in: visibleRect
            ) == expectedFrame)
            #expect(TerminalSelectionGesturePolicy.boundary(
                at: CGPoint(x: expectedFrame.midX, y: expectedFrame.midY),
                startCenter: center,
                endCenter: otherOffscreenCenter,
                in: visibleRect
            ) == .start)
        }
    }

    @Test func boundaryPanArbitratesOnlyHandleOriginsAgainstExactAncestorScrollPans() {
        let outerScroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let innerScroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        let interactionView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        outerScroll.addSubview(innerScroll)
        innerScroll.addSubview(interactionView)

        #expect(TerminalSelectionBoundaryPanGestureRecognizer.shouldPrioritizeHandlePan(
            touchBeganOnHandle: true,
            otherRecognizer: innerScroll.panGestureRecognizer,
            interactionView: interactionView
        ))
        #expect(TerminalSelectionBoundaryPanGestureRecognizer.shouldPrioritizeHandlePan(
            touchBeganOnHandle: true,
            otherRecognizer: outerScroll.panGestureRecognizer,
            interactionView: interactionView
        ))
        #expect(!TerminalSelectionBoundaryPanGestureRecognizer.shouldPrioritizeHandlePan(
            touchBeganOnHandle: false,
            otherRecognizer: innerScroll.panGestureRecognizer,
            interactionView: interactionView
        ))

        let visibleRect = CGRect(x: 0, y: 0, width: 160, height: 160)
        let offscreenBoundary = TerminalSelectionGesturePolicy.boundary(
            at: CGPoint(x: 1, y: 80),
            startCenter: CGPoint(x: -7, y: 80),
            endCenter: CGPoint(x: 1_000, y: 1_000),
            in: visibleRect
        )
        #expect(offscreenBoundary == nil)
        #expect(!TerminalSelectionBoundaryPanGestureRecognizer.shouldPrioritizeHandlePan(
            touchBeganOnHandle: offscreenBoundary != nil,
            otherRecognizer: innerScroll.panGestureRecognizer,
            interactionView: interactionView
        ))

        let otherAncestorPan = UIPanGestureRecognizer()
        innerScroll.addGestureRecognizer(otherAncestorPan)
        #expect(!TerminalSelectionBoundaryPanGestureRecognizer.shouldPrioritizeHandlePan(
            touchBeganOnHandle: true,
            otherRecognizer: otherAncestorPan,
            interactionView: interactionView
        ))

        let siblingScroll = UIScrollView(frame: .zero)
        outerScroll.addSubview(siblingScroll)
        #expect(!TerminalSelectionBoundaryPanGestureRecognizer.shouldPrioritizeHandlePan(
            touchBeganOnHandle: true,
            otherRecognizer: siblingScroll.panGestureRecognizer,
            interactionView: interactionView
        ))
    }

    @Test func longPressArbitratesOnlySelectableOriginsAgainstExactAncestorScrollPans() {
        let outerScroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let innerScroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        let interactionView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        outerScroll.addSubview(innerScroll)
        innerScroll.addSubview(interactionView)

        #expect(TerminalSelectionLongPressGestureRecognizer.shouldPrioritizeSelectionPress(
            touchBeganOnSelectableContent: true,
            otherRecognizer: innerScroll.panGestureRecognizer,
            interactionView: interactionView
        ))
        #expect(TerminalSelectionLongPressGestureRecognizer.shouldPrioritizeSelectionPress(
            touchBeganOnSelectableContent: true,
            otherRecognizer: outerScroll.panGestureRecognizer,
            interactionView: interactionView
        ))
        #expect(!TerminalSelectionLongPressGestureRecognizer.shouldPrioritizeSelectionPress(
            touchBeganOnSelectableContent: false,
            otherRecognizer: innerScroll.panGestureRecognizer,
            interactionView: interactionView
        ))

        let otherAncestorPan = UIPanGestureRecognizer()
        innerScroll.addGestureRecognizer(otherAncestorPan)
        #expect(!TerminalSelectionLongPressGestureRecognizer.shouldPrioritizeSelectionPress(
            touchBeganOnSelectableContent: true,
            otherRecognizer: otherAncestorPan,
            interactionView: interactionView
        ))

        let siblingScroll = UIScrollView(frame: .zero)
        outerScroll.addSubview(siblingScroll)
        #expect(!TerminalSelectionLongPressGestureRecognizer.shouldPrioritizeSelectionPress(
            touchBeganOnSelectableContent: true,
            otherRecognizer: siblingScroll.panGestureRecognizer,
            interactionView: interactionView
        ))
    }

    @Test func boundaryDragSessionPreservesGrabOffsetAndEmitsNoBeginAdjustment() throws {
        let epoch = try #require(TerminalGridEpoch(rawValue: 3))
        var session = TerminalSelectionGesturePolicy.BoundaryDragSession(
            epoch: epoch,
            activeBoundary: .end,
            initialVisualCenter: CGPoint(x: 40, y: 16),
            initialTouch: CGPoint(x: 60, y: 12)
        )

        #expect(session.epoch == epoch)
        #expect(session.activeBoundary == .end)
        #expect(session.initialVisualCenter == CGPoint(x: 40, y: 16))
        #expect(session.grabOffset == CGPoint(x: 20, y: -4))
        #expect(session.adjustmentCenter(for: .began, translation: .zero) == nil)
        #expect(session.adjustmentCenter(
            for: .changed,
            translation: CGPoint(x: 8, y: 4)
        ) == CGPoint(x: 48, y: 20))

        session.retarget(
            to: .start,
            visualCenter: CGPoint(x: 52, y: 20),
            translation: CGPoint(x: 8, y: 4)
        )
        #expect(session.activeBoundary == .start)
        #expect(session.adjustmentCenter(
            for: .changed,
            translation: CGPoint(x: 8, y: 4)
        ) == CGPoint(x: 52, y: 20))
        #expect(session.adjustmentCenter(
            for: .changed,
            translation: CGPoint(x: 12, y: 4)
        ) == CGPoint(x: 56, y: 20))
        #expect(session.grabOffset == CGPoint(x: 16, y: -4))
    }

    @Test func gridEpochGateIgnoresRowsAndCursorButChangesForClearAndReplacement() {
        var grid = CellGrid(cols: 80, rows: 2)
        let initialEpochID = grid.selectionEpochID

        grid.replaceRow(0, raw: "ordinary revision")
        grid.cursor.x = 4
        #expect(grid.selectionEpochID == initialEpochID)

        grid.clear()
        #expect(grid.selectionEpochID != initialEpochID)
        #expect(grid.selectionEpochChangeReason == .clear)

        let replacement = CellGrid(cols: 80, rows: 2)
        #expect(replacement.selectionEpochID != grid.selectionEpochID)
    }

    @Test func recognizedPressDragAndExplicitCopyWriteExactSnapshotText() {
        let clipboard = RecordingTerminalClipboard()
        let feedback = RecordingTerminalSelectionFeedback()
        let controller = TerminalSelectionController(clipboard: clipboard, feedback: feedback)
        let selectionSnapshot = snapshot(["A한B"])
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 16)

        controller.recognizePress(
            at: CGPoint(x: 16, y: 8),
            snapshot: selectionSnapshot,
            geometry: geometry
        )
        #expect(controller.phase == .selecting)
        #expect(!controller.allowsScrolling)

        controller.moveSelection(to: CGPoint(x: 40, y: 8), geometry: geometry)
        controller.endSelection()

        #expect(controller.phase == .selected)
        #expect(controller.selection?.text == "A한B")
        #expect(controller.showsActionControls)
        #expect(clipboard.writes.isEmpty)

        controller.copySelection()

        #expect(clipboard.writes == ["A한B"])
        #expect(controller.phase == .idle)
        #expect(controller.selection == nil)
        #expect(feedback.events == [.selectionStarted, .copyCompleted])
    }

    @Test func controllerAdjustsBoundariesOnlyAfterSelectionCompletes() {
        let controller = TerminalSelectionController(
            clipboard: RecordingTerminalClipboard(),
            feedback: RecordingTerminalSelectionFeedback()
        )
        let selectionSnapshot = snapshot(["ABCD"])
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 16)

        controller.recognizePress(
            at: CGPoint(x: 24, y: 8),
            snapshot: selectionSnapshot,
            geometry: geometry
        )
        controller.moveSelection(to: CGPoint(x: 32, y: 8), geometry: geometry)
        let selecting = controller.selection
        #expect(controller.adjustSelectionBoundary(
            .start,
            toVisualCenter: CGPoint(x: 16, y: 16),
            geometry: geometry,
            epoch: controller.epoch
        ) == nil)
        #expect(controller.selection == selecting)

        controller.endSelection()
        #expect(controller.adjustSelectionBoundary(
            .start,
            toVisualCenter: CGPoint(x: 16, y: 16),
            geometry: geometry,
            epoch: controller.epoch
        ) == .start)
        #expect(controller.selection?.text == "ABC")
    }

    @Test func offCenterHandleGrabAndExactCenterAdjustmentDoNotExpandSelection() throws {
        let controller = TerminalSelectionController(
            clipboard: RecordingTerminalClipboard(),
            feedback: RecordingTerminalSelectionFeedback()
        )
        let selectionSnapshot = snapshot(["ABCDEF"])
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 16)
        controller.recognizePress(
            at: CGPoint(x: 24, y: 8),
            snapshot: selectionSnapshot,
            geometry: geometry
        )
        controller.moveSelection(to: CGPoint(x: 40, y: 8), geometry: geometry)
        controller.endSelection()
        let before = controller.selection
        let epoch = controller.epoch
        let endCenter = try #require(before.flatMap {
            TerminalSelectionOverlayGeometry.handleCenter(
                for: .end,
                selection: $0,
                layout: TerminalGridLayout(cellWidth: 8, lineHeight: 16)
            )
        })
        let session = TerminalSelectionGesturePolicy.BoundaryDragSession(
            epoch: epoch,
            activeBoundary: .end,
            initialVisualCenter: endCenter,
            initialTouch: CGPoint(x: endCenter.x + 20, y: endCenter.y)
        )

        #expect(session.adjustmentCenter(for: .began, translation: .zero) == nil)
        #expect(controller.selection == before)
        let unchangedCenter = try #require(session.adjustmentCenter(
            for: .changed,
            translation: .zero
        ))
        #expect(controller.adjustSelectionBoundary(
            session.activeBoundary,
            toVisualCenter: unchangedCenter,
            geometry: geometry,
            epoch: session.epoch
        ) == .end)
        #expect(controller.selection == before)
        #expect(controller.selection?.text == "BCD")
    }

    @Test func exactCJKBoundaryCentersMapInsideTheSameAtomicGlyph() throws {
        let controller = TerminalSelectionController(
            clipboard: RecordingTerminalClipboard(),
            feedback: RecordingTerminalSelectionFeedback()
        )
        let selectionSnapshot = snapshot(["A한B"])
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 16)
        let layout = TerminalGridLayout(cellWidth: 8, lineHeight: 16)
        controller.recognizePress(
            at: CGPoint(x: 24, y: 8),
            snapshot: selectionSnapshot,
            geometry: geometry
        )
        controller.endSelection()
        let selection = try #require(controller.selection)
        let startCenter = try #require(TerminalSelectionOverlayGeometry.handleCenter(
            for: .start,
            selection: selection,
            layout: layout
        ))
        let endCenter = try #require(TerminalSelectionOverlayGeometry.handleCenter(
            for: .end,
            selection: selection,
            layout: layout
        ))

        #expect(TerminalSelectionOverlayGeometry.adjustmentPosition(
            for: .start,
            visualCenter: startCenter,
            selection: selection,
            geometry: geometry
        ) == TerminalGridPosition(row: 0, column: 1))
        #expect(TerminalSelectionOverlayGeometry.adjustmentPosition(
            for: .end,
            visualCenter: endCenter,
            selection: selection,
            geometry: geometry
        ) == TerminalGridPosition(row: 0, column: 1))
        #expect(controller.adjustSelectionBoundary(
            .start,
            toVisualCenter: startCenter,
            geometry: geometry,
            epoch: controller.epoch
        ) == .start)
        #expect(controller.adjustSelectionBoundary(
            .end,
            toVisualCenter: endCenter,
            geometry: geometry,
            epoch: controller.epoch
        ) == .end)
        #expect(controller.selection?.text == "한")
    }

    @Test func crossingDragRetargetsToTheSwappedVisualHandleWithoutReverseJump() throws {
        let controller = TerminalSelectionController(
            clipboard: RecordingTerminalClipboard(),
            feedback: RecordingTerminalSelectionFeedback()
        )
        let selectionSnapshot = snapshot(["ABCDEFGH"])
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 16)
        let layout = TerminalGridLayout(cellWidth: 8, lineHeight: 16)
        controller.recognizePress(
            at: CGPoint(x: 24, y: 8),
            snapshot: selectionSnapshot,
            geometry: geometry
        )
        controller.moveSelection(to: CGPoint(x: 40, y: 8), geometry: geometry)
        controller.endSelection()
        let initialSelection = try #require(controller.selection)
        let startCenter = try #require(TerminalSelectionOverlayGeometry.handleCenter(
            for: .start,
            selection: initialSelection,
            layout: layout
        ))
        var session = TerminalSelectionGesturePolicy.BoundaryDragSession(
            epoch: controller.epoch,
            activeBoundary: .start,
            initialVisualCenter: startCenter,
            initialTouch: CGPoint(x: startCenter.x + 10, y: startCenter.y)
        )
        let crossingTranslation = CGPoint(x: 28, y: 0)
        let crossingCenter = try #require(session.adjustmentCenter(
            for: .changed,
            translation: crossingTranslation
        ))

        #expect(controller.adjustSelectionBoundary(
            session.activeBoundary,
            toVisualCenter: crossingCenter,
            geometry: geometry,
            epoch: session.epoch
        ) == .end)
        #expect(controller.selection?.text == "DEF")
        let crossedSelection = try #require(controller.selection)
        let crossedCenter = try #require(TerminalSelectionOverlayGeometry.handleCenter(
            for: .end,
            selection: crossedSelection,
            layout: layout
        ))
        session.retarget(
            to: .end,
            visualCenter: crossedCenter,
            translation: crossingTranslation
        )
        #expect(session.adjustmentCenter(
            for: .changed,
            translation: crossingTranslation
        ) == crossedCenter)

        let continuedTranslation = CGPoint(x: 36, y: 0)
        let continuedCenter = try #require(session.adjustmentCenter(
            for: .changed,
            translation: continuedTranslation
        ))
        #expect(controller.adjustSelectionBoundary(
            session.activeBoundary,
            toVisualCenter: continuedCenter,
            geometry: geometry,
            epoch: session.epoch
        ) == .end)
        #expect(controller.selection?.text == "DEFG")
        let continuedSelection = try #require(controller.selection)
        #expect(TerminalSelectionOverlayGeometry.handleCenter(
            for: .end,
            selection: continuedSelection,
            layout: layout
        ) == continuedCenter)
    }

    @Test func epochCapturedAtPanStartRejectsCallbacksAfterGridAdvance() throws {
        let controller = TerminalSelectionController(
            clipboard: RecordingTerminalClipboard(),
            feedback: RecordingTerminalSelectionFeedback()
        )
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 16)
        controller.selectAll(in: snapshot(["ABCD"]))
        let capturedEpoch = controller.epoch
        controller.advanceGridEpoch(reason: .fullSnapshot)
        controller.selectAll(in: snapshot(["WXYZ"]))
        let currentSelection = try #require(controller.selection)

        #expect(controller.adjustSelectionBoundary(
            .end,
            toVisualCenter: CGPoint(x: 32, y: 16),
            geometry: geometry,
            epoch: capturedEpoch
        ) == nil)
        #expect(controller.selection == currentSelection)
        #expect(controller.selection?.text == "WXYZ")
    }

    @Test func overlayGeometryKeepsCJKAtomicAndMarksSelectedEmptyRows() throws {
        let selectionSnapshot = snapshot(["A한B", "", "Z"])
        let selection = try #require(TerminalSelection(
            snapshot: selectionSnapshot,
            anchor: TerminalGridPosition(row: 0, column: 1),
            focus: TerminalGridPosition(row: 2, column: 0)
        ))
        let frames = TerminalSelectionOverlayGeometry.frames(
            for: selection,
            layout: TerminalGridLayout(cellWidth: 8, lineHeight: 16)
        )

        #expect(frames == [
            CGRect(x: 24, y: 8, width: 24, height: 16),
            CGRect(x: 16, y: 24, width: 8, height: 16),
            CGRect(x: 16, y: 40, width: 8, height: 16),
        ])
    }

    @Test func reverseDragUsesTheSameImmutableSnapshot() {
        let controller = TerminalSelectionController(
            clipboard: RecordingTerminalClipboard(),
            feedback: RecordingTerminalSelectionFeedback()
        )
        let selectionSnapshot = snapshot(["A한B"])
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 16)

        controller.recognizePress(
            at: CGPoint(x: 40, y: 8),
            snapshot: selectionSnapshot,
            geometry: geometry
        )
        controller.moveSelection(to: CGPoint(x: 16, y: 8), geometry: geometry)
        controller.endSelection()

        #expect(controller.selection?.anchor == TerminalGridPosition(row: 0, column: 3))
        #expect(controller.selection?.focus == TerminalGridPosition(row: 0, column: 0))
        #expect(controller.selection?.text == "A한B")
    }

    @Test func outsideInsetPressAndRepeatedCancelCopyAreNoOps() {
        let clipboard = RecordingTerminalClipboard()
        let feedback = RecordingTerminalSelectionFeedback()
        let controller = TerminalSelectionController(clipboard: clipboard, feedback: feedback)
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 16)

        controller.recognizePress(
            at: CGPoint(x: 15.99, y: 8),
            snapshot: snapshot(["AB"]),
            geometry: geometry
        )
        controller.endSelection()
        controller.copySelection()
        controller.cancelSelection()
        controller.cancelSelection()

        #expect(controller.phase == .idle)
        #expect(controller.allowsScrolling)
        #expect(clipboard.writes.isEmpty)
        #expect(feedback.events.isEmpty)
    }

    @Test func cancelPinchAndEpochBoundariesClearButOrdinaryRevisionPreserves() {
        let controller = TerminalSelectionController(
            clipboard: RecordingTerminalClipboard(),
            feedback: RecordingTerminalSelectionFeedback()
        )
        let selectionSnapshot = snapshot(["AB", "CD"])

        controller.selectAll(in: selectionSnapshot)
        let immutableSelection = controller.selection
        controller.ordinaryRevisionChanged(to: 7)
        #expect(controller.selection == immutableSelection)

        controller.pinchBegan()
        #expect(controller.selection == nil)

        controller.selectAll(in: selectionSnapshot)
        let previousEpoch = controller.epoch
        controller.advanceGridEpoch(reason: .fullSnapshot)
        #expect(controller.epoch > previousEpoch)
        #expect(controller.selection == nil)

        controller.selectAll(in: selectionSnapshot)
        controller.cancelSelection()
        #expect(controller.selection == nil)
    }

    @Test func accessibilitySelectAllAndCopyPreserveSpacesAndEmptyRows() {
        let clipboard = RecordingTerminalClipboard()
        let feedback = RecordingTerminalSelectionFeedback()
        let controller = TerminalSelectionController(clipboard: clipboard, feedback: feedback)
        let selectionSnapshot = snapshot(["A  ", "", " B "])

        controller.performAccessibilityAction(.selectAll, snapshot: selectionSnapshot)
        #expect(controller.phase == .selected)
        #expect(controller.selection?.text == "A  \n\n B ")
        #expect(controller.selectedLineCount == 3)

        controller.performAccessibilityAction(.copy, snapshot: selectionSnapshot)

        #expect(clipboard.writes == ["A  \n\n B "])
        #expect(controller.selection == nil)
        #expect(feedback.events == [.selectionStarted, .copyCompleted])
    }

    @Test func cursorRenderingRequiresBothCoordinatesInBounds() {
        let cases: [(CursorPos, Bool)] = [
            (CursorPos(x: -1, y: -1), false),
            (CursorPos(x: -1, y: 0), false),
            (CursorPos(x: 0, y: -1), false),
            (CursorPos(x: 4, y: 0), false),
            (CursorPos(x: 0, y: 3), false),
            (CursorPos(x: 0, y: 0), true),
            (CursorPos(x: 3, y: 2), true),
        ]

        for (cursor, expected) in cases {
            #expect(TerminalView.isCursorRenderable(cursor, columns: 4, rows: 3) == expected)
        }
    }

    @Test func viewportBackgroundIsOpaqueBlack() {
        #expect(rgba(UIColor(CmuxTheme.terminalViewportBackground)) == [0, 0, 0, 255])
        #expect(rgba(UIColor(CmuxTheme.terminal)) != [0, 0, 0, 255])
    }

    @Test func terminalCanvasPreservesBlackTruecolorAndSelectionOverlay() throws {
        var grid = CellGrid(cols: 8, rows: 2)
        grid.replaceRow(
            0,
            raw: "\u{1B}[48;2;125;207;255m  "
                + "\u{1B}[48;2;158;206;106m  "
                + "\u{1B}[48;2;224;175;104m  "
                + "\u{1B}[48;2;157;124;216m  \u{1B}[0m"
        )
        grid.cursor = CursorPos(x: -1, y: -1)
        let selectionSnapshot = TerminalSelectionSnapshot(renderRows: grid.renderRows)
        let selection = try #require(TerminalSelection(
            snapshot: selectionSnapshot,
            anchor: TerminalGridPosition(row: 0, column: 0),
            focus: TerminalGridPosition(row: 0, column: 1)
        ))
        let metrics = TerminalFontMetrics(fontSize: 8)
        let renderer = ImageRenderer(content: TerminalCanvas(
            grid: grid,
            fontMetrics: metrics,
            leftInset: 16,
            visibleColumns: 8,
            width: 120,
            height: 48,
            selection: selection,
            showsSelectionHandles: false
        ))
        renderer.scale = 1
        let image = try #require(renderer.uiImage)

        #expect(try pixelRGBA(in: image, x: 2, y: 2) == [0, 0, 0, 255])
        let selectedPixel = try pixelRGBA(in: image, x: 17, y: 9)
        #expect(selectedPixel != [125, 207, 255, 255])
        #expect(selectedPixel[3] == 255)

        let backgrounds: [([UInt8], Int)] = [
            ([158, 206, 106, 255], 2),
            ([224, 175, 104, 255], 4),
            ([157, 124, 216, 255], 6),
        ]
        for (expected, startColumn) in backgrounds {
            let x = Int(16 + CGFloat(startColumn) * metrics.cellWidth + 1)
            #expect(try pixelRGBA(in: image, x: x, y: 9) == expected)
        }
    }

    private func snapshot(_ rows: [String]) -> TerminalSelectionSnapshot {
        var grid = CellGrid(cols: 80, rows: rows.count)
        for (index, row) in rows.enumerated() {
            grid.replaceRow(index, raw: row)
        }
        return TerminalSelectionSnapshot(renderRows: grid.renderRows)
    }

    private func rgba(_ color: UIColor) -> [UInt8] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #expect(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return [red, green, blue, alpha].map { UInt8(round($0 * 255)) }
    }

    private func pixelRGBA(in image: UIImage, x: Int, y: Int) throws -> [UInt8] {
        let source = try #require(image.cgImage)
        let crop = try #require(source.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel
    }
}

@MainActor
private final class RecordingTerminalClipboard: TerminalClipboardWriting {
    private(set) var writes: [String] = []

    func write(_ text: String) {
        writes.append(text)
    }
}

@MainActor
private final class RecordingTerminalSelectionFeedback: TerminalSelectionFeedbackProviding {
    private(set) var events: [TerminalSelectionFeedbackEvent] = []

    func provide(_ event: TerminalSelectionFeedbackEvent) {
        events.append(event)
    }
}
