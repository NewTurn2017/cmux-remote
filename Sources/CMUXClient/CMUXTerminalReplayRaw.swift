import Foundation
import SharedKit

/// Decodes the daemon `terminal.replay` response envelope.
struct CMUXTerminalReplayRaw: Decodable, Equatable, Sendable {
    let columns: Int
    let rows: Int
    let sequence: UInt64
    let surfaceID: String
    let workspaceID: String
    let renderGrid: CMUXRenderGrid

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let verifiedGrid = try container.nestedContainer(
            keyedBy: VerifiedRenderGridCodingKeys.self,
            forKey: .renderGrid
        )

        // Verified replay requires explicit continuity and snapshot semantics even though
        // the lower-level render-grid DTO keeps compatibility defaults for legacy callers.
        _ = try verifiedGrid.decode(UInt64.self, forKey: .renderRevision)
        _ = try verifiedGrid.decode(Bool.self, forKey: .full)
        _ = try verifiedGrid.decode(CMUXRenderGridAnchor.self, forKey: .anchor)

        columns = try container.decode(Int.self, forKey: .columns)
        rows = try container.decode(Int.self, forKey: .rows)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        surfaceID = try container.decode(String.self, forKey: .surfaceID)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        renderGrid = try container.decode(CMUXRenderGrid.self, forKey: .renderGrid)
    }

    var identity: CMUXTerminalReplayIdentity {
        CMUXTerminalReplayIdentity(
            epoch: renderGrid.renderEpoch.rawValue,
            revision: renderGrid.renderRevision.rawValue
        )
    }

    func validate(workspaceId expectedWorkspaceID: String, surfaceId expectedSurfaceID: String) throws {
        guard surfaceID == expectedSurfaceID else {
            throw CMUXTerminalSourceError.surfaceMismatch(
                expected: expectedSurfaceID,
                received: surfaceID
            )
        }
        guard workspaceID == expectedWorkspaceID else {
            throw CMUXTerminalSourceError.workspaceMismatch(
                expected: expectedWorkspaceID,
                received: workspaceID
            )
        }
        guard renderGrid.surfaceID == surfaceID else {
            throw CMUXTerminalSourceError.renderGridSurfaceMismatch(
                envelope: surfaceID,
                renderGrid: renderGrid.surfaceID
            )
        }
        guard renderGrid.stateSeq == sequence else {
            throw CMUXTerminalSourceError.sequenceMismatch(
                envelope: sequence,
                renderGrid: renderGrid.stateSeq
            )
        }
        guard columns == renderGrid.columns, rows == renderGrid.rows else {
            throw CMUXTerminalSourceError.dimensionsMismatch(
                envelopeColumns: columns,
                envelopeRows: rows,
                renderGridColumns: renderGrid.columns,
                renderGridRows: renderGrid.rows
            )
        }
        guard renderGrid.full else {
            throw CMUXTerminalSourceError.nonFullReplay
        }
        guard renderGrid.anchor == .viewport else {
            throw CMUXTerminalSourceError.unexpectedAnchor(renderGrid.anchor.rawValue)
        }
        let epoch = renderGrid.renderEpoch.rawValue
        guard !epoch.isEmpty, UUID(uuidString: epoch) != nil else {
            throw CMUXTerminalSourceError.invalidEpoch(epoch)
        }
    }

    func toScreen(rev: Int) -> Screen {
        CMUXReadTextRaw(text: "", renderGrid: renderGrid).toScreen(rev: rev)
    }

    private enum CodingKeys: String, CodingKey {
        case columns
        case rows
        case sequence = "seq"
        case surfaceID = "surfaceId"
        case workspaceID = "workspaceId"
        case renderGrid
    }

    private enum VerifiedRenderGridCodingKeys: String, CodingKey {
        case renderRevision
        case full
        case anchor
    }
}
