import Foundation

/// Identifies one subscriber lease in a surface render registry.
public struct SurfaceRenderSubscription: Hashable, Sendable {
    /// Surface whose shared render stream is leased.
    public let surfaceId: String

    let id: UUID
    let generation: UUID

    init(
        surfaceId: String,
        id: UUID = UUID(),
        generation: UUID
    ) {
        self.surfaceId = surfaceId
        self.id = id
        self.generation = generation
    }
}
