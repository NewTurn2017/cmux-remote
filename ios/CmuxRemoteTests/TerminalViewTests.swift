import CoreGraphics
import Testing
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
        #expect(!TerminalSelectionGesturePolicy.allowsScrolling(during: .selected))
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

    @Test func recognizedPressDragAndExplicitCopyWriteExactSnapshotText() throws {
        let clipboard = RecordingTerminalClipboard()
        let feedback = RecordingTerminalSelectionFeedback()
        let controller = TerminalSelectionController(clipboard: clipboard, feedback: feedback)
        let snapshot = snapshot(["A한B"])
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 16)

        controller.recognizePress(
            at: CGPoint(x: 16, y: 8),
            snapshot: snapshot,
            geometry: geometry
        )
        #expect(controller.phase == .selecting)
        #expect(!controller.allowsScrolling)

        controller.moveSelection(
            to: CGPoint(x: 40, y: 8),
            geometry: geometry
        )
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
        let snapshot = snapshot(["A한B"])
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 16)

        controller.recognizePress(
            at: CGPoint(x: 40, y: 8),
            snapshot: snapshot,
            geometry: geometry
        )
        controller.moveSelection(
            to: CGPoint(x: 16, y: 8),
            geometry: geometry
        )
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

    @Test func accessibilitySelectAllAndCopyNeedNoDragAndPreserveSpacesAndEmptyRows() {
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

    private func snapshot(_ rows: [String]) -> TerminalSelectionSnapshot {
        var grid = CellGrid(cols: 80, rows: rows.count)
        for (index, row) in rows.enumerated() {
            grid.replaceRow(index, raw: row)
        }
        return TerminalSelectionSnapshot(renderRows: grid.renderRows)
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
