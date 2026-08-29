import Foundation

/// Identifies the scheduler cadence currently selected for a surface.
public enum SurfaceRenderCadence: Equatable, Sendable {
    /// The surface is using the configured interactive frame rate.
    case active

    /// The surface is using the configured quiescent frame rate.
    case idle
}
