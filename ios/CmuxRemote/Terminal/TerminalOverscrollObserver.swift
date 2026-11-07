import SharedKit
import SwiftUI
import UIKit

/// Watches the SwiftUI terminal viewport's backing `UIScrollView` (iOS 17 has
/// no SwiftUI scroll-geometry API) through KVO and a pan-gesture target only,
/// leaving the scroll view's delegate untouched.
struct TerminalOverscrollObserver: UIViewRepresentable {
    var activeScreen: String?
    var interactionBlocked: Bool
    var onPage: (Key) -> Void
    var onHint: (TerminalOverscrollPagingPolicy.Hint) -> Void

    func makeUIView(context: Context) -> TerminalOverscrollObserverView {
        TerminalOverscrollObserverView()
    }

    func updateUIView(_ uiView: TerminalOverscrollObserverView, context: Context) {
        uiView.activeScreen = activeScreen
        uiView.interactionBlocked = interactionBlocked
        uiView.onPage = onPage
        uiView.onHint = onHint
    }

    static func dismantleUIView(_ uiView: TerminalOverscrollObserverView, coordinator: ()) {
        uiView.stopObserving()
    }
}

final class TerminalOverscrollObserverView: UIView {
    var activeScreen: String?
    var interactionBlocked = false
    var onPage: (Key) -> Void = { _ in }
    var onHint: (TerminalOverscrollPagingPolicy.Hint) -> Void = { _ in }

    private weak var scrollView: UIScrollView?
    private var offsetObservation: NSKeyValueObservation?
    private var policy = TerminalOverscrollPagingPolicy()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopObserving()
        } else {
            attachIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.attachIfNeeded()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachIfNeeded()
    }

    func stopObserving() {
        offsetObservation?.invalidate()
        offsetObservation = nil
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(handlePan(_:)))
        scrollView = nil
    }

    private func attachIfNeeded() {
        guard scrollView == nil, let viewport = findViewport() else { return }
        scrollView = viewport
        viewport.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        offsetObservation = viewport.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            MainActor.assumeIsolated { self?.evaluate(scrollView) }
        }
    }

    private func findViewport() -> UIScrollView? {
        var ancestor = superview
        while let current = ancestor {
            if let found = Self.viewport(in: current) { return found }
            ancestor = current.superview
        }
        return nil
    }

    private static func viewport(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView, scrollView.accessibilityIdentifier == "TerminalViewport" {
            return scrollView
        }
        for subview in view.subviews {
            if let found = viewport(in: subview) { return found }
        }
        return nil
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let scrollView else { return }
        switch recognizer.state {
        case .ended, .cancelled, .failed:
            evaluate(scrollView, isTracking: false)
        default:
            evaluate(scrollView)
        }
    }

    private func evaluate(_ scrollView: UIScrollView, isTracking: Bool? = nil) {
        let inset = scrollView.adjustedContentInset
        let overscroll = TerminalOverscrollPagingPolicy.overscroll(
            contentOffsetY: scrollView.contentOffset.y,
            contentHeight: scrollView.contentSize.height,
            boundsHeight: scrollView.bounds.height,
            insetTop: inset.top,
            insetBottom: inset.bottom
        )
        let previousHint = policy.hint
        let key = policy.update(.init(
            activeScreen: activeScreen,
            isTracking: isTracking ?? scrollView.isTracking,
            topOverscroll: overscroll.top,
            bottomOverscroll: overscroll.bottom,
            interactionBlocked: interactionBlocked,
            time: CACurrentMediaTime()
        ))
        if policy.hint != previousHint { onHint(policy.hint) }
        if let key { onPage(key) }
    }
}
