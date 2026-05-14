import Foundation
import SharedKit

public enum CmuxRemoteRPCError: Error, Equatable {
    case rpc(code: String, message: String)
    case missingResult(id: String)
}

extension RPCResponse {
    public func requireOk() throws -> RPCResponse {
        if let error { throw CmuxRemoteRPCError.rpc(code: error.code, message: error.message) }
        return self
    }

    public func unwrapResult() throws -> JSONValue {
        if let error { throw CmuxRemoteRPCError.rpc(code: error.code, message: error.message) }
        guard let result else { throw CmuxRemoteRPCError.missingResult(id: id) }
        return result
    }
}

extension JSONValue {
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try SharedKitJSON.deterministicEncoder.encode(self)
        return try SharedKitJSON.snakeCaseDecoder.decode(T.self, from: data)
    }
}

struct WorkspaceListPayload: Decodable {
    let workspaces: [WorkspacePayload]
}

struct SurfaceListPayload: Decodable {
    let surfaces: [SurfacePayload]
}

struct WorkspacePayload: Decodable {
    let id: String
    let title: String?
    let name: String?
    let index: Int

    var model: Workspace { Workspace(id: id, name: title ?? name ?? id, index: index) }
}

struct SurfacePayload: Decodable {
    let id: String
    let title: String
    let index: Int

    var model: Surface { Surface(id: id, title: title, index: index) }
}


struct SurfaceMutationPayload: Decodable {
    let surfaceId: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let surfaceId = try container.decodeIfPresent(String.self, forKey: .surfaceId) {
            self.surfaceId = surfaceId
        } else if let id = try container.decodeIfPresent(String.self, forKey: .id) {
            self.surfaceId = id
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.surfaceId,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing surface_id")
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case surfaceId
        case id
    }
}

struct ReadTextPayload: Decodable {
    let text: String

    func screen(rev: Int) -> Screen {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let normalizedRows = rows.isEmpty ? [""] : rows
        return Screen(
            rev: rev,
            rows: normalizedRows,
            cols: normalizedRows.map(\.count).max() ?? 0,
            cursor: CursorPos(x: 0, y: 0)
        )
    }
}
