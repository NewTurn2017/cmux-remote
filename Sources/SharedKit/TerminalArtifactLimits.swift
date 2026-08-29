import Foundation

public struct TerminalArtifactLimits: Sendable, Equatable {
    /// Maximum artifacts returned by one scan.
    public static let maxScanItems = 200
    /// Authorization lifetime in seconds.
    public static let authorizationTTLSeconds = 10 * 60
    /// Number of generations retained for one surface.
    public static let generationsPerSurface = 4
    /// Number of surfaces retained by the authorization store.
    public static let retainedSurfaces = 64
    /// Maximum decoded bytes in one fetch response.
    public static let fetchChunkBytes = 3 * 1024 * 1024
    /// Maximum encoded bytes in a full image.
    public static let maxImageBytes = 32 * 1024 * 1024
    /// Maximum image pixel count.
    public static let maxImagePixels = 40_000_000
    /// Default thumbnail dimension in pixels.
    public static let defaultThumbnailDimension = 512
    /// Maximum thumbnail dimension in pixels.
    public static let maxThumbnailDimension = 1024
    /// Maximum encoded thumbnail bytes.
    public static let maxThumbnailBytes = 4 * 1024 * 1024

    private init() {}
}

/// Parameters for `terminal.artifact.scan`.
