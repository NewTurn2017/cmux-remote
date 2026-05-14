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
}

actor StubRPCDispatch: RPCDispatch {
    private(set) var calls: [(method: String, params: JSONValue)] = []
    private var surfaces: [(id: String, title: String)]

    init(surfaces: [(String, String)] = [("s1", "shell")]) {
        self.surfaces = surfaces.map { (id: $0.0, title: $0.1) }
    }

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        calls.append((method, params))
        switch method {
        case "workspace.list":
            return RPCResponse(id: "stub", result: .object([
                "workspaces": .array([.object(["id": .string("w1"), "title": .string("Demo"), "index": .int(0)])])
            ]))
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
        default:
            return RPCResponse(id: "stub", ok: true, result: .object([:]))
        }
    }
}
