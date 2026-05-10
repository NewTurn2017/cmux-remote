import Foundation
import SharedKit

/// Raw cmux v2 socket schemas. The cmux daemon's actual payloads include many
/// fields we don't surface to iOS (remote/proxy state, pane refs, etc.); these
/// types decode the wire shape and translate to the slim `SharedKit` models.
///
/// See `docs/specs/cmux-payload-samples/*.json` for representative responses
/// captured from the running cmux app.

// MARK: workspace.list

struct CMUXWorkspaceListRaw: Decodable {
    let workspaces: [CMUXWorkspaceRaw]
}

struct CMUXWorkspaceRaw: Decodable {
    let id: String
    let title: String
    let index: Int

    func toWorkspace() -> Workspace {
        Workspace(id: id, name: title, index: index)
    }
}

// MARK: workspace.create

/// `workspace.create` returns a single workspace record under the top-level
/// object (cmux nests it inside the same envelope as `workspace.list` on
/// success). We accept both shapes: the bare object, or `{workspace: {...}}`.
struct CMUXWorkspaceCreateRaw: Decodable {
    let workspace: CMUXWorkspaceRaw

    init(from decoder: Decoder) throws {
        if let bare = try? CMUXWorkspaceRaw(from: decoder) {
            self.workspace = bare
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.workspace = try container.decode(CMUXWorkspaceRaw.self, forKey: .workspace)
    }

    private enum CodingKeys: String, CodingKey { case workspace }
}

// MARK: surface.list

struct CMUXSurfaceListRaw: Decodable {
    let surfaces: [CMUXSurfaceRaw]
}

struct CMUXSurfaceRaw: Decodable {
    let id: String
    let title: String
    let index: Int

    func toSurface() -> Surface {
        Surface(id: id, title: title, index: index)
    }
}

// MARK: surface.read_text

/// cmux returns terminal contents as a flat newline-joined `text` string plus
/// a base64 mirror. We synthesize a `Screen` by splitting on `\n`. `cols` is
/// derived from the longest line; `cursor` defaults to `(0,0)` — cmux v2 does
/// not currently expose cursor coordinates over RPC, so the relay's DiffEngine
/// emits a stub cursor until that's added upstream.
struct CMUXReadTextRaw: Decodable {
    let text: String

    func toScreen(rev: Int) -> Screen {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let cols = rows.map { $0.count }.max() ?? 0
        return Screen(rev: rev, rows: rows, cols: cols, cursor: CursorPos(x: 0, y: 0))
    }
}
