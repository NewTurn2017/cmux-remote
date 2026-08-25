import Foundation

/// Tracks monotonic terminal revisions across bounded subscription-generation resets.
struct WebSocketTerminalRevisionState: Sendable {
    private(set) var streamIdentity: UUID
    private(set) var revision: Int
    private var retiredStreamIdentities: [UUID] = []

    init(streamIdentity: UUID, revision: Int) {
        self.streamIdentity = streamIdentity
        self.revision = revision
    }

    /// Accepts equal/newer revisions in the current stream and fresh reset identities.
    ///
    /// Equal revisions intentionally accept the newest authoritative recovery full. A stream
    /// identity change resets revision ordering; up to eight retired identities are rejected
    /// so delayed callbacks from prior subscriptions cannot restore stale state.
    mutating func accept(streamIdentity candidateIdentity: UUID, revision candidateRevision: Int) -> Bool {
        if streamIdentity == candidateIdentity {
            guard candidateRevision >= revision else { return false }
            revision = candidateRevision
            return true
        }
        guard !retiredStreamIdentities.contains(candidateIdentity) else { return false }
        retiredStreamIdentities.append(streamIdentity)
        if retiredStreamIdentities.count > 8 {
            retiredStreamIdentities.removeFirst(retiredStreamIdentities.count - 8)
        }
        streamIdentity = candidateIdentity
        revision = candidateRevision
        return true
    }
}
