import Foundation
import SharedKit

/// Holds one subscriber's snapshot or compatibility-diff delivery callbacks.
struct SurfaceRenderSubscriber: Sendable {
    let onSnapshot: (@Sendable (Screen) async -> Void)?
    let onDiff: (@Sendable (Int, [DiffOp]) -> Void)?
    let onChecksum: @Sendable (String, Int) async -> Void

    init(
        onSnapshot: @escaping @Sendable (Screen) async -> Void,
        onChecksum: @escaping @Sendable (String, Int) async -> Void
    ) {
        self.onSnapshot = onSnapshot
        self.onDiff = nil
        self.onChecksum = onChecksum
    }

    init(
        onDiff: @escaping @Sendable (Int, [DiffOp]) -> Void,
        onChecksum: @escaping @Sendable (String, Int) -> Void
    ) {
        self.onSnapshot = nil
        self.onDiff = onDiff
        self.onChecksum = { hash, revision in
            onChecksum(hash, revision)
        }
    }

    /// Delivers one accepted snapshot through the subscriber's selected seam.
    func deliver(snapshot: Screen, revision: Int, operations: [DiffOp]) async {
        if let onSnapshot {
            await onSnapshot(snapshot)
        } else {
            onDiff?(revision, operations)
        }
    }
}
