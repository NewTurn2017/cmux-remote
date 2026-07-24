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
    let raw: [String: JSONValue]

    var model: Workspace { Workspace(id: id, name: title ?? name ?? id, index: index) }

    var needsInputNotification: NotificationRecord? {
        guard let body = needsInputBody else { return nil }
        let source = needsInputSourceName
        let surfaceId = stringValue(for: "active_surface_id")
            ?? stringValue(for: "activeSurfaceId")
            ?? stringValue(for: "surface_id")
            ?? stringValue(for: "surfaceId")
        let workspaceName = title ?? name ?? id
        return NotificationRecord(
            id: workspaceAlertId(source: source, body: body, surfaceId: surfaceId),
            workspaceId: id,
            surfaceId: surfaceId,
            title: "\(source) needs input",
            subtitle: workspaceName,
            body: body,
            ts: intValue(for: "ts") ?? intValue(for: "updated_at") ?? Int64(Date().timeIntervalSince1970),
            threadId: "workspace-\(id)"
        )
    }

    init(from decoder: Decoder) throws {
        raw = try [String: JSONValue](from: decoder)
        id = raw.stringValue(for: "id") ?? raw.stringValue(for: "workspace_id") ?? raw.stringValue(for: "workspaceId") ?? "unknown"
        title = raw.stringValue(for: "title")
        name = raw.stringValue(for: "name")
        index = Int(raw.intValue(for: "index") ?? 0)
    }

    private var needsInputBody: String? {
        let candidates = [
            "status", "state", "reason", "message", "body", "summary", "subtitle",
            "agent_status", "agentStatus", "last_message", "lastMessage", "prompt",
        ].compactMap { stringValue(for: $0) } + stringLeaves
        return candidates.first { value in
            let normalized = value.normalizedNeedsInputText
            return normalized.containsNeedsInputPhrase && hasKnownNeedsInputSource(including: value)
        }
    }

    private var needsInputSourceName: String {
        let text = (["agent", "source", "app", "kind", "type", "title", "name"].compactMap { stringValue(for: $0) } + stringLeaves)
            .joined(separator: " ")
            .normalizedNeedsInputText
        if text.contains("codex") { return "Codex" }
        if text.contains("openai") { return "OpenAI" }
        if text.contains("claude") { return "Claude Code" }
        return "Agent"
    }

    private func hasKnownNeedsInputSource(including value: String) -> Bool {
        let text = ([value] + ["agent", "source", "app", "kind", "type", "title", "name"].compactMap { stringValue(for: $0) } + stringLeaves)
            .joined(separator: " ")
            .normalizedNeedsInputText
        return text.contains("claude") || text.contains("codex") || text.contains("openai")
    }

    private var stringLeaves: [String] {
        var values: [String] = []
        for value in raw.values { value.appendStringLeaves(to: &values) }
        return values
    }

    private func stringValue(for key: String) -> String? { raw.stringValue(for: key) }
    private func intValue(for key: String) -> Int64? { raw.intValue(for: key) }

    private func workspaceAlertId(source: String, body: String, surfaceId: String?) -> String {
        let raw = ["workspace-alert", id, surfaceId ?? "", source, body].joined(separator: "|")
        let allowed = raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let slug = String(allowed)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(slug.prefix(120))
    }
}

private extension String {
    var normalizedNeedsInputText: String {
        lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    var containsNeedsInputPhrase: Bool {
        contains("needs input")
            || contains("waiting for your input")
            || contains("needs your attention")
            || contains("needs your approval")
            || contains("needs your permission")
            || contains("approval required")
            || contains("permission prompt")
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func stringValue(for key: String) -> String? {
        guard case .string(let value)? = self[key], !value.isEmpty else { return nil }
        return value
    }

    func intValue(for key: String) -> Int64? {
        switch self[key] {
        case .int(let value): return value
        case .double(let value): return Int64(value)
        case .string(let value): return Int64(value)
        default: return nil
        }
    }
}

private extension JSONValue {
    func appendStringLeaves(to values: inout [String]) {
        switch self {
        case .string(let value):
            if !value.isEmpty { values.append(value) }
        case .array(let array):
            for value in array { value.appendStringLeaves(to: &values) }
        case .object(let object):
            for value in object.values { value.appendStringLeaves(to: &values) }
        default:
            break
        }
    }
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

struct SurfaceHistoryPagePayload: Decodable {
    let rows: [String]
    let anchorRows: [String]?
    let nextCursor: String?
}

public struct UploadedFilePayload: Decodable {
    let filename: String
    let path: String
    let bytes: Int
    let mimeType: String
}
