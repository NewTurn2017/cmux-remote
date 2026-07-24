import Foundation
import SharedKit

/// Provides stable, cursor-addressable snapshots of a terminal's scrollback.
///
/// cmux currently exposes only a trailing `lines` argument.  The relay turns
/// that into a real pagination contract by materialising one bounded snapshot
/// on the Mac, then serving immutable pages from it.  A cursor is deliberately
/// opaque to the phone and expires when the relay restarts or its snapshot is
/// evicted.
public actor SurfaceHistoryService {
    public static let maximumSnapshotLines = 100_000
    public static let maximumSnapshots = 8
    public static let maximumPageLines = 500
    /// A prewarm is useful only for a reader who begins browsing shortly
    /// after opening a surface. Reusing an old snapshot creates a hole between
    /// the paged history and the terminal's current bottom rows.
    public static let prewarmFreshness: TimeInterval = 2

    private struct SurfaceKey: Hashable {
        let workspaceId: String
        let surfaceId: String
    }

    private struct Snapshot {
        let workspaceId: String
        let surfaceId: String
        let rows: [String]
        let createdAt: Date
    }

    private let cmux: any CMUXFacade
    private var snapshots: [UUID: Snapshot] = [:]
    private var snapshotOrder: [UUID] = []
    private var newestSnapshotBySurface: [SurfaceKey: UUID] = [:]

    public init(cmux: any CMUXFacade) {
        self.cmux = cmux
    }

    /// Starts the expensive cmux scrollback read before a user reaches the
    /// top of the terminal. It is intentionally fire-and-forget from the WS
    /// subscription path: history pagination subsequently reads only this
    /// in-memory snapshot and never blocks a swipe on a large UDS response.
    public func prewarm(workspaceId: String, surfaceId: String) async {
        let key = SurfaceKey(workspaceId: workspaceId, surfaceId: surfaceId)
        if let id = newestSnapshotBySurface[key],
           let snapshot = snapshots[id],
           isFresh(snapshot)
        {
            return
        }
        _ = try? await createSnapshot(workspaceId: workspaceId, surfaceId: surfaceId, reusingExisting: false)
    }

    /// Returns rows immediately before `cursor`.  With no cursor it also
    /// returns an `anchor_rows` tail: the iOS client keeps that tail frozen
    /// while it browses so new terminal output cannot shift or duplicate the
    /// paged history it is reading.
    public func page(
        workspaceId: String,
        surfaceId: String,
        cursor: String?,
        tailLines: Int,
        limit: Int
    ) async throws -> JSONValue {
        let pageLimit = min(max(limit, 1), Self.maximumPageLines)

        if let cursor {
            let (snapshotId, before) = try parse(cursor: cursor)
            guard let snapshot = snapshots[snapshotId],
                  snapshot.workspaceId == workspaceId,
                  snapshot.surfaceId == surfaceId
            else {
                throw SurfaceHistoryError.cursorExpired
            }
            return page(
                snapshot: snapshot,
                snapshotId: snapshotId,
                before: before,
                limit: pageLimit,
                includeAnchor: false
            )
        }

        let key = SurfaceKey(workspaceId: workspaceId, surfaceId: surfaceId)
        let snapshotId: UUID
        let snapshot: Snapshot
        if let existingId = newestSnapshotBySurface[key],
           let existing = snapshots[existingId],
           isFresh(existing)
        {
            snapshotId = existingId
            snapshot = existing
        } else {
            (snapshotId, snapshot) = try await createSnapshot(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                reusingExisting: false
            )
        }

        let anchorCount = min(max(tailLines, 1), snapshot.rows.count)
        let before = max(0, snapshot.rows.count - anchorCount)
        return page(
            snapshot: snapshot,
            snapshotId: snapshotId,
            before: before,
            limit: pageLimit,
            includeAnchor: true
        )
    }

    private func createSnapshot(
        workspaceId: String,
        surfaceId: String,
        reusingExisting: Bool = true
    ) async throws -> (UUID, Snapshot) {
        let key = SurfaceKey(workspaceId: workspaceId, surfaceId: surfaceId)
        if reusingExisting,
           let existingId = newestSnapshotBySurface[key],
           let existing = snapshots[existingId]
        {
            return (existingId, existing)
        }
        let result = try await cmux.dispatch(
            method: "surface.read_text",
            params: .object([
                "workspace_id": .string(workspaceId),
                "surface_id": .string(surfaceId),
                "lines": .int(Int64(Self.maximumSnapshotLines)),
            ])
        )
        guard case .object(let values) = result,
              case .string(let text)? = values["text"]
        else {
            throw SurfaceHistoryError.invalidResponse
        }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let snapshot = Snapshot(workspaceId: workspaceId, surfaceId: surfaceId, rows: rows, createdAt: Date())
        let snapshotId = UUID()
        snapshots[snapshotId] = snapshot
        snapshotOrder.append(snapshotId)
        newestSnapshotBySurface[key] = snapshotId
        evictSnapshotsIfNeeded()
        return (snapshotId, snapshot)
    }

    private func page(
        snapshot: Snapshot,
        snapshotId: UUID,
        before: Int,
        limit: Int,
        includeAnchor: Bool
    ) -> JSONValue {
        let end = min(max(before, 0), snapshot.rows.count)
        let start = max(0, end - limit)
        let nextCursor = start > 0 ? makeCursor(snapshotId: snapshotId, before: start) : nil

        var result: [String: JSONValue] = [
            "rows": .array(snapshot.rows[start..<end].map(JSONValue.string)),
            "next_cursor": nextCursor.map(JSONValue.string) ?? .null,
        ]
        if includeAnchor {
            result["anchor_rows"] = .array(snapshot.rows[end...].map(JSONValue.string))
        }
        return .object(result)
    }

    private func makeCursor(snapshotId: UUID, before: Int) -> String {
        "\(snapshotId.uuidString).\(before)"
    }

    private func parse(cursor: String) throws -> (UUID, Int) {
        let components = cursor.split(separator: ".", maxSplits: 1).map(String.init)
        guard components.count == 2,
              let id = UUID(uuidString: components[0]),
              let before = Int(components[1]),
              before >= 0
        else {
            throw SurfaceHistoryError.cursorExpired
        }
        return (id, before)
    }

    private func evictSnapshotsIfNeeded() {
        while snapshotOrder.count > Self.maximumSnapshots {
            let oldest = snapshotOrder.removeFirst()
            if let snapshot = snapshots.removeValue(forKey: oldest) {
                let key = SurfaceKey(
                    workspaceId: snapshot.workspaceId,
                    surfaceId: snapshot.surfaceId
                )
                if newestSnapshotBySurface[key] == oldest {
                    newestSnapshotBySurface[key] = nil
                }
            }
        }
    }

    private func isFresh(_ snapshot: Snapshot) -> Bool {
        Date().timeIntervalSince(snapshot.createdAt) <= Self.prewarmFreshness
    }
}

public enum SurfaceHistoryError: LocalizedError {
    case cursorExpired
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .cursorExpired: return "terminal history cursor expired"
        case .invalidResponse: return "cmux returned an invalid terminal history response"
        }
    }
}
