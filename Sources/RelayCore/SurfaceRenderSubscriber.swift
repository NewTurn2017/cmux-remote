import Foundation
import SharedKit

/// Holds the established diff and checksum callbacks for one subscriber lease.
struct SurfaceRenderSubscriber: Sendable {
    let onDiff: @Sendable (Int, [DiffOp]) -> Void
    let onChecksum: @Sendable (String, Int) -> Void
}
