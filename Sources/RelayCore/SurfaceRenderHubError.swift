import Foundation

/// Reports a bounded registry or subscription rejection.
public enum SurfaceRenderHubError: Error, Equatable, Sendable {
    /// The registry already owns its configured maximum number of surfaces.
    case surfaceLimitReached(Int)

    /// The surface already belongs to a different workspace in this registry.
    case workspaceMismatch(surfaceId: String, expected: String, received: String)

    /// The surface already owns its configured maximum number of subscribers.
    case subscriberLimitReached(surfaceId: String, limit: Int)

    /// The hub has entered terminal lifecycle cleanup and accepts no new subscribers.
    case stopped(surfaceId: String)
}
