import Foundation
import SharedKit

extension CMUXClient {
    public func workspaceList() async throws -> [Workspace] {
        let resp = try await call(method: "workspace.list", params: .object([:]))
        return try resp.unwrapResult().decode([String: [Workspace]].self)["workspaces"] ?? []
    }

    public func workspaceCreate(name: String) async throws -> Workspace {
        let resp = try await call(method: "workspace.create",
                                  params: .object(["name": .string(name)]))
        return try resp.unwrapResult().decode(Workspace.self)
    }

    public func workspaceSelect(id: String) async throws {
        _ = try await call(method: "workspace.select",
                           params: .object(["workspace_id": .string(id)])).requireOk()
    }

    public func workspaceClose(id: String) async throws {
        _ = try await call(method: "workspace.close",
                           params: .object(["workspace_id": .string(id)])).requireOk()
    }

    public func surfaceList(workspaceId: String) async throws -> [Surface] {
        let resp = try await call(method: "surface.list",
                                  params: .object(["workspace_id": .string(workspaceId)]))
        return try resp.unwrapResult().decode([String: [Surface]].self)["surfaces"] ?? []
    }

    public func surfaceSendText(workspaceId: String, surfaceId: String, text: String) async throws {
        _ = try await call(method: "surface.send_text",
                           params: .object([
                               "workspace_id": .string(workspaceId),
                               "surface_id": .string(surfaceId),
                               "text": .string(text),
                           ])).requireOk()
    }

    public func surfaceSendKey(workspaceId: String, surfaceId: String, key: Key) async throws {
        let encoded = KeyEncoder.encode(key)
        _ = try await call(method: "surface.send_key",
                           params: .object([
                               "workspace_id": .string(workspaceId),
                               "surface_id": .string(surfaceId),
                               "key": .string(encoded),
                           ])).requireOk()
    }

    public func surfaceReadText(workspaceId: String, surfaceId: String, lines: Int)
        async throws -> Screen
    {
        let resp = try await call(method: "surface.read_text",
                                  params: .object([
                                      "workspace_id": .string(workspaceId),
                                      "surface_id": .string(surfaceId),
                                      "lines": .int(Int64(lines)),
                                  ]))
        return try resp.unwrapResult().decode(Screen.self)
    }

    public func notificationCreate(workspaceId: String, surfaceId: String?, title: String,
                                   subtitle: String?, body: String) async throws
    {
        var params: [String: JSONValue] = [
            "workspace_id": .string(workspaceId),
            "title": .string(title),
            "body": .string(body),
        ]
        if let s = surfaceId { params["surface_id"] = .string(s) }
        if let s = subtitle  { params["subtitle"]  = .string(s) }
        _ = try await call(method: "notification.create", params: .object(params)).requireOk()
    }
}

extension RPCResponse {
    public func requireOk() throws -> RPCResponse {
        if let e = error { throw CMUXClientError.rpc(e) }
        return self
    }

    public func unwrapResult() throws -> JSONValue {
        if let e = error { throw CMUXClientError.rpc(e) }
        guard let r = result else {
            throw CMUXClientError.decoding("ok=true but result is nil for id=\(id)")
        }
        return r
    }
}

extension JSONValue {
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try SharedKitJSON.deterministicEncoder.encode(self)
        return try SharedKitJSON.snakeCaseDecoder.decode(T.self, from: data)
    }
}
