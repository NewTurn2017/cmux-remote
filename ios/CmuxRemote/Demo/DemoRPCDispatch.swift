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

    public init() {}

    public func setOnSubscribe(_ handler: @escaping SubscribeHandler) {
        self.onSubscribe = handler
    }

    public func call(method: String, params: JSONValue) async throws -> RPCResponse {
        switch method {
        case "workspace.list":
            return RPCResponse(id: "demo", result: .object([
                "workspaces": .array(DemoContent.workspaces.enumerated().map { index, ws in
                    .object([
                        "id": .string(ws.id),
                        "title": .string(ws.title),
                        "index": .int(Int64(index)),
                    ])
                }),
            ]))

        case "surface.list":
            guard case .object(let p) = params,
                  case .string(let workspaceId)? = p["workspace_id"],
                  let workspace = DemoContent.workspaces.first(where: { $0.id == workspaceId })
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
               let surface = DemoContent.surface(for: surfaceId)
            {
                return RPCResponse(id: "demo", result: .object([
                    "text": .string(surface.screen.joined(separator: "\n")),
                ]))
            }
            return RPCResponse(id: "demo", result: .object(["text": .string("")]))

        case "surface.create":
            return RPCResponse(id: "demo", result: .object([
                "surface_id": .string("SF-DEMO-NEW-\(UUID().uuidString.prefix(8))"),
            ]))

        case "surface.unsubscribe",
             "surface.close",
             "surface.send_text",
             "surface.send_key",
             "surface.focus",
             "pane.last",
             "pane.focus",
             "notification.create":
            return RPCResponse(id: "demo", ok: true, result: .object([:]))

        case "pane.list":
            return RPCResponse(id: "demo", result: .object(["panes": .array([])]))

        default:
            return RPCResponse(id: "demo", ok: true, result: .object([:]))
        }
    }
}
