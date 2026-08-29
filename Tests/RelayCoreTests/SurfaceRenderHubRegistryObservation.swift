import Foundation
@testable import RelayCore

enum SurfaceRenderHubRegistryObservation: Equatable, Sendable {
    case started(String)
    case reserved(SurfaceRenderSubscription)
    case registered(SurfaceRenderSubscription)
}
