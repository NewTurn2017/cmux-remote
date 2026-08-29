import Foundation

/// Identifies one revision within a render-grid producer lifetime.
public struct CMUXTerminalReplayIdentity: Equatable, Sendable {
    /// The render producer lifetime identifier.
    public let epoch: String

    /// The monotonic revision within ``epoch``.
    public let revision: UInt64

    /// Creates a producer identity for a decoded replay.
    ///
    /// - Parameters:
    ///   - epoch: Producer lifetime identifier.
    ///   - revision: Monotonic revision within the producer lifetime.
    public init(epoch: String, revision: UInt64) {
        self.epoch = epoch
        self.revision = revision
    }
}
