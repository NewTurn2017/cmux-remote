import Foundation
import SharedKit
import Testing
@testable import CMUXClient

/// Opt-in byte measurement for the relay scrollback retention rule.
///
/// Reads one `terminal.replay` result from `CMUX_REPLAY_MEASURE_PATH` (intended to be a named
/// pipe so terminal contents never land on disk) and writes only counts to
/// `CMUX_REPLAY_MEASURE_OUT`. Skipped when the variables are absent.
@Suite("ScreenFullRetentionMeasurementTests")
struct ScreenFullRetentionMeasurementTests {
    private static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["CMUX_REPLAY_MEASURE_PATH"] != nil
                   && environment["CMUX_REPLAY_MEASURE_OUT"] != nil))
    func compareLegacy120AndViewportPlus240ScreenFullBytes() throws {
        let inputPath = try #require(Self.environment["CMUX_REPLAY_MEASURE_PATH"])
        let outputPath = try #require(Self.environment["CMUX_REPLAY_MEASURE_OUT"])
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: inputPath))
        let input = try #require(try handle.readToEnd())
        try handle.close()

        var payload = try SharedKitJSON.snakeCaseDecoder.decode(JSONValue.self, from: input)
        if case .object(let object) = payload, let result = object["result"] {
            payload = result
        }
        let replay = try payload.decode(CMUXTerminalReplayRaw.self)
        let grid = replay.renderGrid

        let current = replay.toScreen(rev: 1)
        let legacy = Self.legacy120Screen(grid: grid)
        let currentBytes = try Self.screenFullBytes(current, surfaceId: replay.surfaceID)
        let legacyBytes = try Self.screenFullBytes(legacy, surfaceId: replay.surfaceID)

        let report: [String: Any] = [
            "surface_id": replay.surfaceID,
            "active_screen": grid.activeScreen.rawValue,
            "viewport_rows": grid.rows,
            "columns": grid.columns,
            "scrollback_rows": grid.scrollbackRows,
            "old_rule": "last 120 rows (scrollback + viewport)",
            "old_rows": legacy.rows.count,
            "old_screenfull_bytes": legacyBytes,
            "new_rule": "viewport rows + min(scrollback, 240)",
            "new_rows": current.rows.count,
            "new_screenfull_bytes": currentBytes,
            "replay_result_bytes": input.count,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outputPath))
        print("screenFullBytes old=\(legacyBytes) rows=\(legacy.rows.count) new=\(currentBytes) rows=\(current.rows.count)")
        #expect(current.rows.count == grid.rows + min(grid.scrollbackRows, CMUXReadTextRaw.retainedScrollbackLimit))
    }

    /// Rebuilds the pre-change relay output: the last 120 combined rows, as a pre-activeScreen relay sent them.
    private static func legacy120Screen(grid: CMUXRenderGrid) -> Screen {
        let allRows = grid.canonicalANSIRows()
        let retained = Array(allRows.suffix(120))
        let dropped = allRows.count - retained.count
        var cursor = CursorPos.hidden
        if let source = grid.cursor, source.visible {
            let row = grid.scrollbackRows + source.row - dropped
            if retained.indices.contains(row) { cursor = CursorPos(x: source.column, y: row) }
        }
        return Screen(rev: 1, rows: retained, cols: grid.columns, cursor: cursor)
    }

    private static func screenFullBytes(_ screen: Screen, surfaceId: String) throws -> Int {
        try SharedKitJSON.deterministicEncoder.encode(
            PushFrame.screenFull(ScreenFull(surfaceId: surfaceId, screen: screen))
        ).count
    }
}
