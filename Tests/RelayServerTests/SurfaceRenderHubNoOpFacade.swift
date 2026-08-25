import SharedKit
@testable import RelayServer

struct SurfaceRenderHubNoOpFacade: CMUXFacade {
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        .object([:])
    }
}
