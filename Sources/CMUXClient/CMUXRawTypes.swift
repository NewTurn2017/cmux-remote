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

/// Translates compatible plain-text and render-grid daemon responses to `Screen`.
///
/// A validated render grid is authoritative when present. Legacy responses keep
/// their original newline splitting, column derivation, and stub cursor behavior.
struct CMUXReadTextRaw: Decodable {
    let text: String
    let renderGrid: CMUXRenderGrid?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        renderGrid = try container.decodeIfPresent(CMUXRenderGrid.self, forKey: .renderGrid)
    }

    func toScreen(rev: Int) -> Screen {
        if let renderGrid {
            return Screen(
                rev: rev,
                rows: renderGrid.canonicalANSIRows(),
                cols: renderGrid.columns,
                cursor: CursorPos(x: 0, y: 0)
            )
        }

        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let cols = rows.map { $0.count }.max() ?? 0
        return Screen(rev: rev, rows: rows, cols: cols, cursor: CursorPos(x: 0, y: 0))
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case renderGrid
    }
}
