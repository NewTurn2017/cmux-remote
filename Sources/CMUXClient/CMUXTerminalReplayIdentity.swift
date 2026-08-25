import Foundation

/// Identifies one revision within a render-grid producer lifetime.
public struct CMUXTerminalReplayIdentity: Equatable, Sendable {
    /// The render producer lifetime identifier.
    public let epoch: String

    /// The monotonic revision within ``epoch``.
    public let revision: UInt64

    init(epoch: String, revision: UInt64) {
        self.epoch = epoch
        self.revision = revision
    }
}
