import Foundation

/// Registry-owned active generation and its synchronously tracked leases.
struct SurfaceRenderHubRegistryEntry: Sendable {
    let generation: UUID
    let workspaceId: String
    let hub: SurfaceRenderHub
    var leaseIDs: Set<UUID>
}
