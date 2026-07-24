import XCTest
import SharedKit
@testable import CmuxRemote

@MainActor
final class ChecksumReconcileTests: XCTestCase {
    func testMismatchTriggersFullRequest() async {
        let rpc = StubRPCDispatch()
        let store = SurfaceStore(rpc: rpc)
        store.subscribed = "s"
        store.subscribedWorkspaceId = "w"
        let frame = try! JSONDecoder().decode(ScreenFull.self, from: Data(#"{"surface_id":"s","rev":1,"rows":["a","b"],"cols":1,"rowsCount":2,"cursor":{"x":0,"y":0}}"#.utf8))
        store.ingest(.screenFull(frame))
        store.ingest(.screenChecksum(ScreenChecksum(surfaceId: "s", rev: 1, hash: "deadbeef00000000")))
        try? await Task.sleep(nanoseconds: 30_000_000)
        let calls = await rpc.calls
        XCTAssertTrue(calls.contains { $0.method == "surface.read_text" })
    }

    func testMatchingChecksumUsesRawAnsiRowsAndAvoidsFullRequest() async {
        let rpc = StubRPCDispatch()
        let store = SurfaceStore(rpc: rpc)
        store.subscribed = "s"
        store.subscribedWorkspaceId = "w"
        let rows = ["\u{1B}[38;5;202mhot\u{1B}[0m", "plain"]
        let cursor = CursorPos(x: 1, y: 0)
        store.ingest(.screenFull(ScreenFull(
            surfaceId: "s",
            rev: 2,
            rows: rows,
            cols: 5,
            rowsCount: rows.count,
            cursor: cursor
        )))

        let hash = ScreenHasher.hash(Screen(rev: 2, rows: rows, cols: 5, cursor: cursor))
        store.ingest(.screenChecksum(ScreenChecksum(surfaceId: "s", rev: 2, hash: hash)))

        try? await Task.sleep(nanoseconds: 30_000_000)
        let calls = await rpc.calls
        XCTAssertFalse(calls.contains { $0.method == "surface.read_text" })
    }
}

actor StubRPCDispatch: RPCDispatch {
    private(set) var calls: [(method: String, params: JSONValue)] = []
    private var workspaces: [(id: String, title: String)]
    private var surfaces: [(id: String, title: String)]
    private var workspaceExtras: [String: [String: JSONValue]]
    private var historyRequests = 0

    init(
        workspaces: [(String, String)] = [("w1", "Demo")],
        surfaces: [(String, String)] = [("s1", "shell")],
        workspaceExtras: [String: [String: JSONValue]] = [:]
    ) {
        self.workspaces = workspaces.map { (id: $0.0, title: $0.1) }
        self.surfaces = surfaces.map { (id: $0.0, title: $0.1) }
        self.workspaceExtras = workspaceExtras
    }

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        calls.append((method, params))
        switch method {
        case "workspace.list":
            return RPCResponse(id: "stub", result: .object([
                "workspaces": .array(workspaces.enumerated().map { index, workspace in
                    var payload: [String: JSONValue] = [
                        "id": .string(workspace.id),
                        "title": .string(workspace.title),
                        "index": .int(Int64(index)),
                    ]
                    for (key, value) in workspaceExtras[workspace.id] ?? [:] {
                        payload[key] = value
                    }
                    return .object(payload)
                })
            ]))
        case "workspace.create":
            if case .object(let params) = params {
                let title: String
                if case .string(let value)? = params["title"] {
                    title = value
                } else if case .string(let value)? = params["name"] {
                    title = value
                } else {
                    title = "Terminal \(workspaces.count + 1)"
                }
                let workspaceId = "w\(workspaces.count + 1)"
                workspaces.append((workspaceId, title))
                return RPCResponse(id: "stub", ok: true, result: .object([
                    "workspace_id": .string(workspaceId),
                    "workspace": .object([
                        "id": .string(workspaceId),
                        "title": .string(title),
                        "index": .int(Int64(workspaces.count - 1)),
                    ]),
                ]))
            }
            return RPCResponse(id: "stub", ok: true, result: .object([:]))
        case "workspace.rename":
            if case .object(let params) = params,
               case .string(let workspaceId)? = params["workspace_id"],
               case .string(let title)? = params["title"],
               let index = workspaces.firstIndex(where: { $0.id == workspaceId })
            {
                workspaces[index].title = title
            }
            return RPCResponse(id: "stub", ok: true, result: .object([:]))
        case "workspace.close":
            if case .object(let params) = params, case .string(let workspaceId)? = params["workspace_id"] {
                workspaces.removeAll { $0.id == workspaceId }
                surfaces.removeAll()
            }
            return RPCResponse(id: "stub", ok: true, result: .object([:]))
        case "surface.list":
            return RPCResponse(id: "stub", result: .object([
                "surfaces": .array(surfaces.enumerated().map { index, surface in
                    .object([
                        "id": .string(surface.id),
                        "title": .string(surface.title),
                        "index": .int(Int64(index)),
                    ])
                })
            ]))
        case "surface.create":
            let id = "s\(surfaces.count + 1)"
            surfaces.append((id, "shell \(surfaces.count + 1)"))
            return RPCResponse(id: "stub", result: .object(["surface_id": .string(id)]))
        case "surface.close":
            if case .object(let params) = params, case .string(let surfaceId)? = params["surface_id"] {
                surfaces.removeAll { $0.id == surfaceId }
            }
            return RPCResponse(id: "stub", ok: true, result: .object([:]))
        case "surface.read_text":
            return RPCResponse(id: "stub", result: .object(["text": .string("fresh")]))
        case "surface.history":
            historyRequests += 1
            if historyRequests == 1 {
                return RPCResponse(id: "stub", result: .object([
                    "rows": .array([.string("older-2")]),
                    "anchor_rows": .array([.string("fresh")]),
                    "next_cursor": .string("older-page"),
                ]))
            }
            return RPCResponse(id: "stub", result: .object([
                "rows": .array([.string("older-1")]),
                "next_cursor": .null,
            ]))
        case "file.upload":
            return RPCResponse(id: "stub", result: .object([
                "filename": .string("photo.jpg"),
                "path": .string("/Users/demo/Downloads/cmux-remote/photo.jpg"),
                "bytes": .int(3),
                "mime_type": .string("image/jpeg"),
            ]))
        case "host.battery":
            return RPCResponse(id: "stub", result: .object([
                "available": .bool(true),
                "percent": .int(88),
                "state": .string("charged"),
                "is_charging": .bool(true),
                "power_source": .string("AC Power"),
            ]))
        default:
            return RPCResponse(id: "stub", ok: true, result: .object([:]))
        }
    }
}
