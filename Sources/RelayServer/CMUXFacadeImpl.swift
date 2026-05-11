import Foundation
import RelayCore
import CMUXClient
import SharedKit

/// Translates the JSON-RPC dispatch surface that `WebSocketHandler` exposes
/// into typed `CMUXClient.call` requests against the cmux daemon. Methods
/// the relay handles directly (e.g. `surface.subscribe`) are intercepted
/// upstream by `Session` and never reach this facade.
public final class CMUXFacadeImpl: CMUXFacade, @unchecked Sendable {
    private let connection: CmuxConnection

    public init(connection: CmuxConnection) {
        self.connection = connection
    }

    public func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        let client = try await connection.connect()
        let resp = try await client.call(method: method, params: params)
        return try resp.unwrapResult()
    }
}
