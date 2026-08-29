import Foundation
import SharedKit

/// Retains one subscribed surface's bounded reconciliation baseline and stream identity.
struct SessionSurfaceState: Sendable {
    var baseline: Screen?
    let streamIdentity = UUID()
}
