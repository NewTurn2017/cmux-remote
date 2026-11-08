import Foundation
import SharedKit
@testable import CmuxRemote

actor DocumentRPCStub: RPCDispatch {
    enum Plan: Sendable {
        case response(RPCResponse)
        case gate(String)
    }

    private var plans: [String: [Plan]] = [:]
    private var calls: [(method: String, params: JSONValue)] = []
    private var gatedCalls: [String: CheckedContinuation<RPCResponse, Never>] = [:]
    private var reachedGates: Set<String> = []
    private var gateWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func enqueue(_ plan: Plan, for method: String) {
        plans[method, default: []].append(plan)
    }

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        calls.append((method, params))
        guard var queue = plans[method], !queue.isEmpty else {
            return DocumentFixtures.error("unexpected_call")
        }
        let plan = queue.removeFirst()
        plans[method] = queue
        switch plan {
        case .response(let response):
            return response
        case .gate(let id):
            reachedGates.insert(id)
            for waiter in gateWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
            return await withCheckedContinuation { gatedCalls[id] = $0 }
        }
    }

    func waitUntilReached(_ gate: String) async {
        if reachedGates.contains(gate) { return }
        await withCheckedContinuation { gateWaiters[gate, default: []].append($0) }
    }

    func release(_ gate: String, with response: RPCResponse) {
        gatedCalls.removeValue(forKey: gate)?.resume(returning: response)
    }

    func callCount(method: String) -> Int {
        calls.filter { $0.method == method }.count
    }

    func params(method: String) -> [JSONValue] {
        calls.filter { $0.method == method }.map(\.params)
    }
}

enum DocumentFixtures {
    static func artifact(
        id: String = "doc",
        filename: String = "README.md",
        mimeType: String = "text/markdown",
        bytes: Int,
        revision: String = "r1"
    ) -> TerminalArtifact {
        TerminalArtifact(
            artifactId: id,
            filename: filename,
            mimeType: mimeType,
            bytes: bytes,
            revision: revision,
            isImage: false
        )
    }

    static func openResponse(_ artifacts: [TerminalArtifact], generation: Int = 1) throws -> RPCResponse {
        let data = try SharedKitJSON.snakeCaseEncoder.encode(
            TerminalArtifactScanResult(generation: generation, artifacts: artifacts)
        )
        return RPCResponse(id: "open", ok: true, result: try JSONDecoder().decode(JSONValue.self, from: data))
    }

    static func fetchResponse(
        artifactID: String = "doc",
        offset: Int,
        total: Int,
        revision: String = "r1",
        data: Data,
        eof: Bool
    ) -> RPCResponse {
        RPCResponse(id: "fetch", result: .object([
            "artifact_id": .string(artifactID),
            "offset": .int(Int64(offset)),
            "total_bytes": .int(Int64(total)),
            "revision": .string(revision),
            "data_base64": .string(data.base64EncodedString()),
            "eof": .bool(eof),
        ]))
    }

    static func error(_ code: String) -> RPCResponse {
        RPCResponse(id: "error", ok: false, error: RPCError(code: code, message: code))
    }
}
