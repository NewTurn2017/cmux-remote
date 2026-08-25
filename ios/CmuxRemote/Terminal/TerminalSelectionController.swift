import CoreGraphics
import Observation

/// Bridges terminal selection gestures and actions to the pure reducer and UIKit seams.
@MainActor
@Observable
final class TerminalSelectionController {
    private var reducer: TerminalSelectionReducer
    private let clipboard: any TerminalClipboardWriting
    private let feedback: any TerminalSelectionFeedbackProviding

    init(
        epoch: TerminalGridEpoch = .initial,
        revision: Int = 0,
        clipboard: any TerminalClipboardWriting,
        feedback: any TerminalSelectionFeedbackProviding
    ) {
        reducer = TerminalSelectionReducer(epoch: epoch, revision: revision)
        self.clipboard = clipboard
        self.feedback = feedback
    }

    convenience init(epoch: TerminalGridEpoch = .initial, revision: Int = 0) {
        self.init(
            epoch: epoch,
            revision: revision,
            clipboard: SystemTerminalClipboard(),
            feedback: SystemTerminalSelectionFeedback()
        )
    }

    var epoch: TerminalGridEpoch { reducer.epoch }
    var phase: TerminalSelectionReducerPhase { reducer.phase }
    var selection: TerminalSelection? { reducer.selection }
    var allowsScrolling: Bool { TerminalSelectionGesturePolicy.allowsScrolling(during: phase) }
    var showsActionControls: Bool { phase == .selected && selection != nil }

    var selectedCharacterCount: Int {
        selection?.text.count ?? 0
    }

    var selectedLineCount: Int {
        guard let text = selection?.text else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    func recognizePress(
        at point: CGPoint,
        snapshot: TerminalSelectionSnapshot,
        geometry: TerminalGridGeometry
    ) {
        guard let position = geometry.strictPosition(at: point, in: snapshot) else { return }
        let previousPhase = phase
        reducer.reduce(.recognizedPress(snapshot: snapshot, at: position, epoch: epoch))
        if previousPhase != .selecting, phase == .selecting {
            feedback.provide(.selectionStarted)
        }
    }

    func moveSelection(to point: CGPoint, geometry: TerminalGridGeometry) {
        guard let selection,
              let position = geometry.clampedPosition(at: point, in: selection.snapshot)
        else { return }
        let event: TerminalSelectionReducerEvent = position < selection.anchor
            ? .reverse(to: position, epoch: epoch)
            : .move(to: position, epoch: epoch)
        reducer.reduce(event)
    }

    func endSelection() {
        reducer.reduce(.end(epoch: epoch))
    }

    func cancelSelection() {
        reducer.reduce(.cancel)
    }

    func copySelection() {
        guard case .copyText(let text) = reducer.reduce(.copy(epoch: epoch)) else { return }
        clipboard.write(text)
        feedback.provide(.copyCompleted)
    }

    func pinchBegan() {
        reducer.reduce(.pinch)
    }

    func ordinaryRevisionChanged(to revision: Int) {
        reducer.reduce(.ordinaryRevisionChanged(to: revision))
    }

    func advanceGridEpoch(reason: TerminalGridEpochChangeReason) {
        guard epoch.rawValue < Int.max,
              let nextEpoch = TerminalGridEpoch(rawValue: epoch.rawValue + 1)
        else {
            cancelSelection()
            return
        }
        reducer.reduce(.epochChanged(to: nextEpoch, reason: reason))
    }

    func selectAll(in snapshot: TerminalSelectionSnapshot) {
        guard let firstRow = snapshot.rows.indices.first(where: { !snapshot.rows[$0].spans.isEmpty }),
              let firstSpan = snapshot.rows[firstRow].spans.first,
              let lastRow = snapshot.rows.indices.last(where: { !snapshot.rows[$0].spans.isEmpty }),
              let lastSpan = snapshot.rows[lastRow].spans.last
        else { return }

        let start = TerminalGridPosition(row: firstRow, column: firstSpan.columns.lowerBound)
        let end = TerminalGridPosition(row: lastRow, column: lastSpan.columns.lowerBound)
        let previousPhase = phase
        reducer.reduce(.recognizedPress(snapshot: snapshot, at: start, epoch: epoch))
        reducer.reduce(.move(to: end, epoch: epoch))
        reducer.reduce(.end(epoch: epoch))
        if previousPhase == .idle, phase == .selected {
            feedback.provide(.selectionStarted)
        }
    }

    func performAccessibilityAction(
        _ action: TerminalSelectionAccessibilityAction,
        snapshot: TerminalSelectionSnapshot
    ) {
        switch action {
        case .selectAll:
            selectAll(in: snapshot)
        case .copy:
            copySelection()
        }
    }
}
