import Foundation
import RelayCore
import CMUXClient
import SharedKit

/// Translates the JSON-RPC dispatch surface that `WebSocketHandler` exposes
/// into typed `CMUXClient.call` requests against the cmux daemon. Methods
/// the relay handles directly (e.g. `surface.subscribe`) are intercepted
/// upstream by `Session` and never reach this facade.
public final class CMUXFacadeImpl: CMUXFacade, @unchecked Sendable {
    public enum Lane: Sendable {
        case realtime
        case history
    }

    private let connection: CmuxConnection
    private let lane: Lane

    public init(connection: CmuxConnection, lane: Lane = .realtime) {
        self.connection = connection
        self.lane = lane
    }

    public func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        let client: CMUXClient
        switch lane {
        case .realtime:
            client = try await connection.connect()
        case .history:
            client = try await connection.connectForHistory()
        }
        let resp = try await client.call(method: method, params: params)
        return try resp.unwrapResult()
    }
}
