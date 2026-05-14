import Foundation
import Observation
import SharedKit

@MainActor
@Observable
public final class WorkspaceStore {
    public var workspaces: [Workspace] = []
    public var selectedId: String?
    public var surfacesByWorkspaceId: [String: [Surface]] = [:]
    public var connection: ConnectionState = .disconnected

    private let rpc: any RPCDispatch

    public init(rpc: any RPCDispatch) {
        self.rpc = rpc
    }

    public func refresh() async {
        connection = .connecting
        do {
            let response = try await rpc.call(method: "workspace.list", params: .object([:]))
            let payload = try response.unwrapResult().decode(WorkspaceListPayload.self)
            let loaded = payload.workspaces.map(\.model).sorted { $0.index < $1.index }
            workspaces = loaded
            if selectedId == nil || !loaded.contains(where: { $0.id == selectedId }) {
                selectedId = loaded.first?.id
            }
            for workspace in loaded {
                await refreshSurfaces(workspaceId: workspace.id)
            }
            connection = .connected
        } catch {
            connection = .error(String(describing: error))
        }
    }

    public func refreshSurfaces(workspaceId: String) async {
        do {
            let response = try await rpc.call(
                method: "surface.list",
                params: .object(["workspace_id": .string(workspaceId)])
            )
            let payload = try response.unwrapResult().decode(SurfaceListPayload.self)
            surfacesByWorkspaceId[workspaceId] = payload.surfaces.map(\.model).sorted { $0.index < $1.index }
        } catch {
            surfacesByWorkspaceId[workspaceId] = []
        }
    }

    public func surfaces(for workspaceId: String) -> [Surface] {
        surfacesByWorkspaceId[workspaceId] ?? []
    }

    public func surfaceCount(for workspaceId: String) -> Int {
        surfaces(for: workspaceId).count
    }

    public func create(name: String) async throws {
        _ = try await rpc.call(method: "workspace.create", params: .object(["name": .string(name)])).requireOk()
        await refresh()
    }

    public func createSurface(workspaceId: String) async throws -> Surface {
        let response = try await rpc.call(
            method: "surface.create",
            params: .object([
                "workspace_id": .string(workspaceId),
                "type": .string("terminal"),
                "focus": .bool(true),
            ])
        )
        let payload = try response.unwrapResult().decode(SurfaceMutationPayload.self)
        await refreshSurfaces(workspaceId: workspaceId)
        if let surface = surfaces(for: workspaceId).first(where: { $0.id == payload.surfaceId }) {
            return surface
        }
        return Surface(id: payload.surfaceId, title: "terminal", index: surfaces(for: workspaceId).count)
    }

    public func closeSurface(workspaceId: String, surfaceId: String) async throws {
        _ = try await rpc.call(
            method: "surface.close",
            params: .object([
                "workspace_id": .string(workspaceId),
                "surface_id": .string(surfaceId),
            ])
        ).requireOk()
        await refreshSurfaces(workspaceId: workspaceId)
    }

    public func reset() {
        workspaces = []
        selectedId = nil
        surfacesByWorkspaceId = [:]
        connection = .disconnected
    }
}

public enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}
