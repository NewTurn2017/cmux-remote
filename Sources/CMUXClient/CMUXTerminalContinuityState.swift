import Foundation

/// Stores replay continuity independently from decoded screen payloads.
struct CMUXTerminalContinuityState: Sendable {
    /// Hard ceiling for orphaned identities, sized well above expected active relay surfaces.
    ///
    /// Each entry contains only identifiers and revisions; 256 bounds adversarial surface churn
    /// while leaving ample headroom for a large interactive cmux session.
    static let maximumTrackedSurfaces = 256

    /// Number of recent producer lifetimes retained to reject epoch flip-flops.
    ///
    /// Eight protects ordinary restart/reconnect churn without allowing one long-lived surface
    /// to accumulate producer UUIDs indefinitely.
    static let maximumRetiredEpochsPerSurface = 8

    private var identities: [String: CMUXTerminalReplayIdentity] = [:]
    private var retiredEpochs: [String: [String]] = [:]

    /// Least-recently-used key first; contains exactly the keys in ``identities``.
    private var recency: [String] = []

    var count: Int { identities.count }

    static func key(workspaceId: String, surfaceId: String) -> String {
        workspaceId + "\u{0}" + surfaceId
    }

    mutating func classify(
        identity: CMUXTerminalReplayIdentity,
        key: String
    ) -> CMUXTerminalReplayDisposition {
        guard let current = identities[key] else {
            identities[key] = identity
            touch(key)
            evictOverflow()
            return .accept
        }
        touch(key)
        if current.epoch == identity.epoch {
            if current.revision == identity.revision {
                return .unchanged
            }
            if identity.revision < current.revision {
                return .ignored(.staleRevision(
                    received: identity.revision,
                    current: current.revision
                ))
            }
            identities[key] = identity
            return .accept
        }
        if retiredEpochs[key, default: []].contains(identity.epoch) {
            return .ignored(.retiredEpoch(identity.epoch))
        }

        var recentEpochs = retiredEpochs[key, default: []]
        recentEpochs.removeAll { $0 == current.epoch }
        recentEpochs.append(current.epoch)
        if recentEpochs.count > Self.maximumRetiredEpochsPerSurface {
            recentEpochs.removeFirst(recentEpochs.count - Self.maximumRetiredEpochsPerSurface)
        }
        retiredEpochs[key] = recentEpochs
        identities[key] = identity
        return .accept
    }

    mutating func release(key: String) {
        identities.removeValue(forKey: key)
        retiredEpochs.removeValue(forKey: key)
        recency.removeAll { $0 == key }
    }

    mutating func reset() {
        identities.removeAll(keepingCapacity: false)
        retiredEpochs.removeAll(keepingCapacity: false)
        recency.removeAll(keepingCapacity: false)
    }

    private mutating func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private mutating func evictOverflow() {
        while identities.count > Self.maximumTrackedSurfaces {
            let evictedKey = recency.removeFirst()
            identities.removeValue(forKey: evictedKey)
            retiredEpochs.removeValue(forKey: evictedKey)
        }
    }
}
