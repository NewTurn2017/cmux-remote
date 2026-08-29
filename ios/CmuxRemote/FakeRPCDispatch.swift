import SharedKit

actor FakeRPCDispatch: RPCDispatch {
    private var workspaces: [(id: String, title: String)] = [("WS-FAKE", "Demo Workspace")]
    private var surfaces: [(id: String, title: String)] = [("SF-FAKE", "shell")]

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        switch method {
        case "workspace.list":
            return RPCResponse(id: "fake", result: .object([
                "workspaces": .array(workspaces.enumerated().map { index, workspace in
                    .object([
                        "id": .string(workspace.id),
                        "title": .string(workspace.title),
                        "index": .int(Int64(index)),
                    ])
                }),
            ]))
        case "workspace.create":
            let title: String
            if case .object(let params) = params, case .string(let value)? = params["title"] {
                title = value
            } else if case .object(let params) = params, case .string(let value)? = params["name"] {
                title = value
            } else {
                title = "Terminal \(workspaces.count + 1)"
            }
            let workspaceId = "WS-FAKE-\(workspaces.count + 1)"
            workspaces.append((workspaceId, title))
            if surfaces.isEmpty { surfaces.append(("SF-FAKE", "shell")) }
            return RPCResponse(id: "fake", ok: true, result: .object([
                "workspace_id": .string(workspaceId),
                "workspace": .object([
                    "id": .string(workspaceId),
                    "title": .string(title),
                    "index": .int(Int64(workspaces.count - 1)),
                ]),
            ]))
        case "workspace.rename":
            if case .object(let params) = params,
               case .string(let workspaceId)? = params["workspace_id"],
               case .string(let title)? = params["title"],
               let index = workspaces.firstIndex(where: { $0.id == workspaceId })
            {
                workspaces[index].title = title
            }
            return RPCResponse(id: "fake", ok: true, result: .object([:]))
        case "workspace.close":
            if case .object(let params) = params,
               case .string(let workspaceId)? = params["workspace_id"],
               workspaces.count > 1
            {
                workspaces.removeAll { $0.id == workspaceId }
            }
            return RPCResponse(id: "fake", ok: true, result: .object([:]))
        case "surface.list":
            return RPCResponse(id: "fake", result: .object([
                "surfaces": .array(surfaces.enumerated().map { index, surface in
                    .object([
                        "id": .string(surface.id),
                        "title": .string(surface.title),
                        "index": .int(Int64(index)),
                    ])
                }),
            ]))
        case "surface.create":
            let nextIndex = surfaces.count + 1
            let id = "SF-FAKE-\(nextIndex)"
            surfaces.append((id, "shell \(nextIndex)"))
            return RPCResponse(id: "fake", result: .object(["surface_id": .string(id)]))
        case "surface.close":
            if case .object(let params) = params,
               case .string(let surfaceId)? = params["surface_id"],
               surfaces.count > 1
            {
                surfaces.removeAll { $0.id == surfaceId }
            }
            return RPCResponse(id: "fake", ok: true, result: .object([:]))
        case "surface.subscribe", "surface.unsubscribe", "surface.send_text", "surface.send_key", "surface.focus":
            return RPCResponse(id: "fake", ok: true, result: .object([:]))
        case "host.battery":
            return RPCResponse(id: "fake", ok: true, result: .object([
                "available": .bool(true),
                "percent": .int(88),
                "state": .string("charged"),
                "is_charging": .bool(true),
                "power_source": .string("AC Power"),
            ]))
        case "file.upload":
            return RPCResponse(id: "fake", ok: true, result: .object([
                "filename": .string("demo-image.jpg"),
                "path": .string("/Users/demo/Downloads/cmux-remote/demo-image.jpg"),
                "bytes": .int(42),
                "mime_type": .string("image/jpeg"),
            ]))
        case "surface.read_text":
            return RPCResponse(id: "fake", result: .object(["text": .string("hello from fake relay")]))
        default:
            return RPCResponse(id: "fake", ok: true, result: .object([:]))
        }
    }
}
