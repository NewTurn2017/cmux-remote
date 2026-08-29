import Foundation

/// Registry-owned retirement task for one removed surface generation.
struct SurfaceRenderHubRetirement: Sendable {
    let generation: UUID
    let task: Task<Void, Never>
}
