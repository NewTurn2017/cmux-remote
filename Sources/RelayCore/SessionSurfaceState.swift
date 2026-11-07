import Foundation
import SharedKit

/// Retains one subscribed surface's bounded reconciliation baseline and stream identity.
struct SessionSurfaceState: Sendable {
    var baseline: Screen?
    /// Set once the shared hub classified this surface as a non-terminal.
    var isNotTerminal = false
    let streamIdentity = UUID()
}
