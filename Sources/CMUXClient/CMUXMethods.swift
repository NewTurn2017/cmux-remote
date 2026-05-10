import Foundation
import SharedKit

extension CMUXClient {
    public func workspaceList() async throws -> [Workspace] {
        let resp = try await call(method: "workspace.list", params: .object([:]))
        let raw = try resp.unwrapResult().decode(CMUXWorkspaceListRaw.self)
        return raw.workspaces.map { $0.toWorkspace() }
    }

    public func workspaceCreate(name: String) async throws -> Workspace {
        let resp = try await call(method: "workspace.create",
                                  params: .object(["name": .string(name)]))
        let raw = try resp.unwrapResult().decode(CMUXWorkspaceCreateRaw.self)
        return raw.workspace.toWorkspace()
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
        let raw = try resp.unwrapResult().decode(CMUXSurfaceListRaw.self)
        return raw.surfaces.map { $0.toSurface() }
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
        let raw = try resp.unwrapResult().decode(CMUXReadTextRaw.self)
        // `rev` is a relay-internal counter (DiffEngine bumps per tick); the
        // cmux response has no equivalent, so we hand back 0 here and let
        // callers stamp their own rev.
        return raw.toScreen(rev: 0)
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
