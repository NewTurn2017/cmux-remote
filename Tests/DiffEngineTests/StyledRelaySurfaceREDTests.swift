import Foundation
import Testing
import SharedKit
@testable import CMUXClient
@testable import RelayCore

/// RED driver for the production response-to-screen boundary. The fixture is
/// a terminal replay-shaped response with today's plain `text` fallback and
/// the future `render_grid` payload. It decodes through CMUXReadTextRaw and
/// feeds that production Screen through DiffEngine and PushFrame unchanged.
@Suite("StyledRelaySurfaceREDTests")
struct StyledRelaySurfaceREDTests {
    @Test func styledReplayBackgroundReachesRelayRowANSI() async throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "07-terminal-replay-green-block",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let raw = try SharedKitJSON.snakeCaseDecoder.decode(
            CMUXReadTextRaw.self,
            from: Data(contentsOf: fixtureURL)
        )
        let screen = raw.toScreen(rev: 0)
        #expect(screen.rows.contains { $0.contains("GREEN BLOCK") })

        let engine = DiffEngine(
            reader: ProductionScreenReader(screen: screen),
            fps: 15,
            idleFps: 5,
            workspaceId: "workspace-red",
            surfaceId: "surface-red",
            lines: screen.rows.count,
            clock: FakeClock()
        )
        try await confirmation("DiffEngine emits the styled row", expectedCount: 1) { emitted in
            await engine.setOnDiff { revision, ops in
                let frame = PushFrame.screenDiff(
                    ScreenDiff(surfaceId: "surface-red", rev: revision, ops: ops)
                )
                guard let rowANSI = Self.relayRowText(in: frame, row: 0) else {
                    Issue.record("production diff omitted row 0")
                    emitted()
                    return
                }
                #expect(rowANSI.contains("GREEN BLOCK"))
                #expect(
                    rowANSI.contains("\u{1B}[38;2;234;234;234;48;2;40;50;40m"),
                    "styled background #283228 is absent from the production-generated PushFrame row ANSI: \(rowANSI.debugDescription)"
                )
                emitted()
            }

            try await engine.tick()
        }
    }

    private static func relayRowText(in frame: PushFrame, row: Int) -> String? {
        guard case .screenDiff(let diff) = frame else { return nil }
        for op in diff.ops {
            if case .row(let y, let text) = op, y == row {
                return text
            }
        }
        return nil
    }
}

private actor ProductionScreenReader: SurfaceReader {
    let screen: Screen

    init(screen: Screen) {
        self.screen = screen
    }

    func read(workspaceId: String, surfaceId: String, lines: Int) async throws -> Screen {
        screen
    }
}
