import Foundation
import SharedKit

/// RPC dispatch backing Demo Mode. Mirrors the small slice of the wire
/// protocol the iOS app actually exercises (workspace.list, surface.list,
/// surface.subscribe / send_text / send_key) and routes the rest to a
/// benign `ok` response so demo navigation never trips error handling.
///
/// Holds an `onSubscribe` hook so the app layer can push a corresponding
/// `screen.full` frame into `SurfaceStore` the moment a surface chip is
/// tapped — without that, the terminal mirror would stay blank in demo
/// mode (real mode populates it via WS push).
public actor DemoRPCDispatch: RPCDispatch {
    public typealias SubscribeHandler = @Sendable (String) async -> Void

    private var onSubscribe: SubscribeHandler?
    private var workspaces: [DemoWorkspace]

    public init() {
        self.workspaces = DemoContent.workspaces
    }

    public func setOnSubscribe(_ handler: @escaping SubscribeHandler) {
        self.onSubscribe = handler
    }

    public func call(method: String, params: JSONValue) async throws -> RPCResponse {
        switch method {
        case "workspace.list":
            return RPCResponse(id: "demo", result: .object([
                "workspaces": .array(workspaces.enumerated().map { index, ws in
                    var payload: [String: JSONValue] = [
                        "id": .string(ws.id),
                        "title": .string(ws.title),
                        "index": .int(Int64(index)),
                    ]
                    if ws.id == "WS-DEMO-1" {
                        payload["agent"] = .string("Claude Code")
                        payload["status"] = .string("Claude is waiting for your input")
                        payload["summary"] = .string("Claude needs your permission")
                        payload["active_surface_id"] = .string("SF-DEMO-1A")
                    }
                    return .object(payload)
                }),
            ]))

        case "surface.list":
            guard case .object(let p) = params,
                  case .string(let workspaceId)? = p["workspace_id"],
                  let workspace = workspaces.first(where: { $0.id == workspaceId })
            else {
                return RPCResponse(id: "demo", result: .object(["surfaces": .array([])]))
            }
            return RPCResponse(id: "demo", result: .object([
                "surfaces": .array(workspace.surfaces.enumerated().map { index, surface in
                    .object([
                        "id": .string(surface.id),
                        "title": .string(surface.title),
                        "index": .int(Int64(index)),
                    ])
                }),
            ]))

        case "surface.subscribe":
            if case .object(let p) = params,
               case .string(let surfaceId)? = p["surface_id"]
            {
                await onSubscribe?(surfaceId)
            }
            return RPCResponse(id: "demo", ok: true, result: .object([:]))

        case "surface.read_text":
            if case .object(let p) = params,
               case .string(let surfaceId)? = p["surface_id"],
               let surface = surface(for: surfaceId)
            {
                return RPCResponse(id: "demo", result: .object([
                    "text": .string(surface.screen.joined(separator: "\n")),
                ]))
            }
            return RPCResponse(id: "demo", result: .object(["text": .string("")]))

        case "surface.history":
            if case .object(let p) = params,
               case .string(let surfaceId)? = p["surface_id"],
               let surface = surface(for: surfaceId)
            {
                return RPCResponse(id: "demo", result: .object([
                    "rows": .array([]),
                    "anchor_rows": .array(surface.screen.map(JSONValue.string)),
                    "next_cursor": .null,
                ]))
            }
            return RPCResponse(id: "demo", result: .object([
                "rows": .array([]),
                "anchor_rows": .array([]),
                "next_cursor": .null,
            ]))

        case "workspace.create":
            let title: String
            if case .object(let p) = params, case .string(let value)? = p["title"] {
                title = value
            } else if case .object(let p) = params, case .string(let value)? = p["name"] {
                title = value
            } else {
                title = "Terminal \(workspaces.count + 1)"
            }
            let workspaceId = "WS-DEMO-NEW-\(UUID().uuidString.prefix(8))"
            let workspace = DemoWorkspace(
                id: workspaceId,
                title: title,
                surfaces: [DemoSurface(id: "SF-DEMO-NEW-\(UUID().uuidString.prefix(8))", title: "shell", screen: ["$", "", "new demo workspace"])]
            )
            workspaces.append(workspace)
            return RPCResponse(id: "demo", ok: true, result: .object([
                "workspace_id": .string(workspaceId),
                "workspace": .object([
                    "id": .string(workspace.id),
                    "title": .string(workspace.title),
                    "index": .int(Int64(workspaces.count - 1)),
                ]),
            ]))

        case "workspace.rename":
            if case .object(let p) = params,
               case .string(let title)? = p["title"]
            {
                let workspaceId: String?
                if case .string(let id)? = p["workspace_id"] {
                    workspaceId = id
                } else {
                    workspaceId = workspaces.first?.id
                }
                if let workspaceId, let index = workspaces.firstIndex(where: { $0.id == workspaceId }) {
                    let old = workspaces[index]
                    workspaces[index] = DemoWorkspace(id: old.id, title: title, surfaces: old.surfaces)
                }
            }
            return RPCResponse(id: "demo", ok: true, result: .object([:]))

        case "workspace.close":
            if case .object(let p) = params, case .string(let workspaceId)? = p["workspace_id"], workspaces.count > 1 {
                workspaces.removeAll { $0.id == workspaceId }
            }
            return RPCResponse(id: "demo", ok: true, result: .object([:]))

        case "surface.create":
            guard case .object(let p) = params,
                  case .string(let workspaceId)? = p["workspace_id"],
                  let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceId })
            else {
                return RPCResponse(id: "demo", result: .object([
                    "surface_id": .string("SF-DEMO-NEW-\(UUID().uuidString.prefix(8))"),
                ]))
            }
            let old = workspaces[workspaceIndex]
            let nextIndex = old.surfaces.count + 1
            let surfaceId = "SF-DEMO-NEW-\(UUID().uuidString.prefix(8))"
            let surface = DemoSurface(id: surfaceId, title: "shell \(nextIndex)", screen: ["$", "", "new demo surface"])
            workspaces[workspaceIndex] = DemoWorkspace(id: old.id, title: old.title, surfaces: old.surfaces + [surface])
            return RPCResponse(id: "demo", result: .object([
                "surface_id": .string(surfaceId),
            ]))

        case "surface.close":
            if case .object(let p) = params,
               case .string(let workspaceId)? = p["workspace_id"],
               case .string(let surfaceId)? = p["surface_id"],
               let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceId })
            {
                let old = workspaces[workspaceIndex]
                if old.surfaces.count > 1 {
                    workspaces[workspaceIndex] = DemoWorkspace(
                        id: old.id,
                        title: old.title,
                        surfaces: old.surfaces.filter { $0.id != surfaceId }
                    )
                }
            }
            return RPCResponse(id: "demo", ok: true, result: .object([:]))

        case "surface.unsubscribe",
             "surface.send_text",
             "surface.send_key",
             "surface.focus",
             "notification.create":
            return RPCResponse(id: "demo", ok: true, result: .object([:]))

        case "file.upload":
            return RPCResponse(id: "demo", ok: true, result: .object([
                "filename": .string("demo-image.jpg"),
                "path": .string("/Users/demo/Downloads/cmux-remote/demo-image.jpg"),
                "bytes": .int(42),
                "mime_type": .string("image/jpeg"),
            ]))

        case "host.battery":
            return RPCResponse(id: "demo", ok: true, result: .object([
                "available": .bool(true),
                "percent": .int(88),
                "state": .string("charged"),
                "is_charging": .bool(true),
                "power_source": .string("AC Power"),
            ]))

        default:
            return RPCResponse(id: "demo", ok: true, result: .object([:]))
        }
    }

    private func surface(for id: String) -> DemoSurface? {
        for workspace in workspaces {
            if let surface = workspace.surfaces.first(where: { $0.id == id }) {
                return surface
            }
        }
        return nil
    }
}
