import CoreGraphics

/// Defines the gesture thresholds and scroll arbitration for terminal selection.
struct TerminalSelectionGesturePolicy {
    enum BoundaryDragUpdate: Equatable, Sendable {
        case began
        case changed
        case ended
    }

    struct BoundaryDragSession: Equatable, Sendable {
        let epoch: TerminalGridEpoch
        private(set) var activeBoundary: TerminalSelection.Boundary
        let initialVisualCenter: CGPoint
        private(set) var grabOffset: CGPoint
        private var referenceVisualCenter: CGPoint
        private var referenceTranslation: CGPoint = .zero

        init(
            epoch: TerminalGridEpoch,
            activeBoundary: TerminalSelection.Boundary,
            initialVisualCenter: CGPoint,
            initialTouch: CGPoint
        ) {
            self.epoch = epoch
            self.activeBoundary = activeBoundary
            self.initialVisualCenter = initialVisualCenter
            grabOffset = CGPoint(
                x: initialTouch.x - initialVisualCenter.x,
                y: initialTouch.y - initialVisualCenter.y
            )
            referenceVisualCenter = initialVisualCenter
        }

        func adjustmentCenter(
            for update: BoundaryDragUpdate,
            translation: CGPoint
        ) -> CGPoint? {
            guard update != .began else { return nil }
            return targetCenter(for: translation)
        }

        mutating func retarget(
            to boundary: TerminalSelection.Boundary,
            visualCenter: CGPoint,
            translation: CGPoint
        ) {
            let previousTarget = targetCenter(for: translation)
            let currentFinger = CGPoint(
                x: previousTarget.x + grabOffset.x,
                y: previousTarget.y + grabOffset.y
            )
            activeBoundary = boundary
            referenceVisualCenter = visualCenter
            referenceTranslation = translation
            grabOffset = CGPoint(
                x: currentFinger.x - visualCenter.x,
                y: currentFinger.y - visualCenter.y
            )
        }

        private func targetCenter(for translation: CGPoint) -> CGPoint {
            CGPoint(
                x: referenceVisualCenter.x + translation.x - referenceTranslation.x,
                y: referenceVisualCenter.y + translation.y - referenceTranslation.y
            )
        }
    }

    static let minimumPressDuration = 0.4
    static let maximumPressDistance: CGFloat = 12
    static let minimumDragDistance: CGFloat = 0
    static let visibleHandleDiameter: CGFloat = 12
    static let visibleHandleOutlineWidth: CGFloat = 2
    static let handleHitDiameter: CGFloat = 44

    static func allowsScrolling(during phase: TerminalSelectionReducerPhase) -> Bool {
        phase != .selecting
    }

    static func boundedHitFrame(
        for visibleCenter: CGPoint,
        in visibleRect: CGRect
    ) -> CGRect? {
        let visibleSide = visibleHandleDiameter
        let visibleFrame = CGRect(
            x: visibleCenter.x - visibleSide / 2,
            y: visibleCenter.y - visibleSide / 2,
            width: visibleSide,
            height: visibleSide
        )
        guard visibleFrame.intersects(visibleRect) else { return nil }

        let side = handleHitDiameter
        let halfSide = side / 2
        let minimumX = visibleRect.minX
        let maximumX = visibleRect.maxX - side
        let minimumY = visibleRect.minY
        let maximumY = visibleRect.maxY - side
        return CGRect(
            x: minimumX <= maximumX
                ? min(max(visibleCenter.x - halfSide, minimumX), maximumX)
                : visibleRect.midX - halfSide,
            y: minimumY <= maximumY
                ? min(max(visibleCenter.y - halfSide, minimumY), maximumY)
                : visibleRect.midY - halfSide,
            width: side,
            height: side
        )
    }

    static func boundary(
        at point: CGPoint,
        startCenter: CGPoint,
        endCenter: CGPoint,
        in bounds: CGRect
    ) -> TerminalSelection.Boundary? {
        let candidates: [(TerminalSelection.Boundary, CGPoint, CGRect)] = [
            (TerminalSelection.Boundary.start, startCenter),
            (TerminalSelection.Boundary.end, endCenter),
        ].compactMap { boundary, visibleCenter in
            guard let hitFrame = boundedHitFrame(for: visibleCenter, in: bounds) else {
                return nil
            }
            return (boundary, visibleCenter, hitFrame)
        }

        return candidates
            .filter { $0.2.contains(point) }
            .map { boundary, visibleCenter, _ in
                let deltaX = point.x - visibleCenter.x
                let deltaY = point.y - visibleCenter.y
                return (boundary, deltaX * deltaX + deltaY * deltaY)
            }
            .min { $0.1 < $1.1 }?
            .0
    }
}
