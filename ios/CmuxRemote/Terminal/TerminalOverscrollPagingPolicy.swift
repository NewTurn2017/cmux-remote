import CoreGraphics
import Foundation
import SharedKit

/// Turns an edge overscroll of the terminal viewport into one `page_up` /
/// `page_down` per pull, only while the mirrored program owns the alternate
/// screen (fullscreen TUIs keep no scrollback for local scrolling to reveal).
struct TerminalOverscrollPagingPolicy: Equatable {
    static let threshold: CGFloat = 56
    static let minimumInterval: TimeInterval = 0.35
    static let hintThreshold: CGFloat = 8
    static let alternateScreen = "alternate"

    enum Edge: Equatable, Sendable {
        case top
        case bottom

        var key: Key { self == .top ? .pageUp : .pageDown }
    }

    enum Hint: Equatable, Sendable {
        case idle
        case pulling(Edge)
        case sent(Edge)
    }

    struct Sample: Equatable, Sendable {
        var activeScreen: String?
        var isTracking: Bool
        var topOverscroll: CGFloat
        var bottomOverscroll: CGFloat
        var interactionBlocked: Bool
        var time: TimeInterval
    }

    private(set) var hint: Hint = .idle
    private var firedEdge: Edge?
    private var lastSent: [Edge: TimeInterval] = [:]

    static func overscroll(
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        boundsHeight: CGFloat,
        insetTop: CGFloat,
        insetBottom: CGFloat
    ) -> (top: CGFloat, bottom: CGFloat) {
        let minOffset = -insetTop
        let maxOffset = max(minOffset, contentHeight + insetBottom - boundsHeight)
        return (max(0, minOffset - contentOffsetY), max(0, contentOffsetY - maxOffset))
    }

    mutating func update(_ sample: Sample) -> Key? {
        guard sample.isTracking else {
            firedEdge = nil
            hint = .idle
            return nil
        }
        guard sample.activeScreen == Self.alternateScreen, !sample.interactionBlocked else {
            hint = .idle
            return nil
        }
        if let firedEdge {
            hint = .sent(firedEdge)
            return nil
        }
        let edge: Edge?
        if sample.topOverscroll >= Self.threshold {
            edge = .top
        } else if sample.bottomOverscroll >= Self.threshold {
            edge = .bottom
        } else {
            edge = nil
        }
        guard let edge else {
            if sample.topOverscroll >= Self.hintThreshold {
                hint = .pulling(.top)
            } else if sample.bottomOverscroll >= Self.hintThreshold {
                hint = .pulling(.bottom)
            } else {
                hint = .idle
            }
            return nil
        }
        if let last = lastSent[edge], sample.time - last < Self.minimumInterval {
            hint = .pulling(edge)
            return nil
        }
        firedEdge = edge
        lastSent[edge] = sample.time
        hint = .sent(edge)
        return edge.key
    }
}
