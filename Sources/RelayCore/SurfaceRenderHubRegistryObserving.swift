import Foundation

/// Observes acquisition boundaries for deterministic actor integration tests.
protocol SurfaceRenderHubRegistryObserving: Sendable {
    func acquisitionDidStart(surfaceId: String) async
    func acquisitionDidReserve(_ subscription: SurfaceRenderSubscription) async
    func acquisitionDidRegister(_ subscription: SurfaceRenderSubscription) async
}
