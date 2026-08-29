import Foundation
import Testing
import SharedKit
@testable import CMUXClient
@testable import RelayCore

@Suite("ScreenFidelityTests")
struct ScreenFidelityTests {
    @Test func cjkUsesRenderGridColumnsAndRealCursor() throws {
        let screen = try Self.screen(
            columns: 4,
            rows: 1,
            cursorRow: 0,
            cursorColumn: 3,
            rowSpans: [[
                "row": 0,
                "column": 0,
                "style_id": 0,
                "text": "A한B",
                "cell_width": 4,
            ]]
        )

        #expect(screen.cols == 4)
        #expect(screen.cursor == CursorPos(x: 3, y: 0))
        #expect(Self.visibleText(screen.rows[0]) == "A한B")
        #expect(screen.snapshotMetadata == ScreenSnapshotMetadata(
            renderEpoch: "00000000-0000-4000-8000-000000000001",
            renderRevision: 2,
            viewportRows: 1,
            terminalForeground: "#eaeaea",
            terminalBackground: "#101820",
            terminalThemeRevision: 9
        ))
    }

    @Test func backgroundOnlyStyleChangeChangesRowHashAndEmitsRowDiff() throws {
        let before = try Self.screen(background: "#283228", revision: 2)
        let after = try Self.screen(background: "#382838", revision: 2)
        var state = RowState()

        _ = state.ingest(snapshot: before)
        let ops = state.ingest(snapshot: after)

        #expect(ScreenHasher.rowHash(before.rows[0]) != ScreenHasher.rowHash(after.rows[0]))
        #expect(ops == [.row(y: 0, text: after.rows[0])])
    }

    @Test func columnResizeForcesFullResetAtDiffBoundary() throws {
        let before = try Self.screen(columns: 4)
        let after = try Self.screen(columns: 5, cursorColumn: 1, revision: 3)
        var state = RowState()

        _ = state.ingest(snapshot: before)
        let ops = state.ingest(snapshot: after)

        #expect(ops.first == .clear)
        #expect(ops.contains(.row(y: 0, text: after.rows[0])))
        #expect(ops.last == .cursor(x: after.cursor.x, y: after.cursor.y))
    }

    @Test func epochChangeForcesFullResetAtDiffEngineBoundary() async throws {
        let before = try Self.screen(epoch: "00000000-0000-4000-8000-000000000001")
        let after = try Self.screen(epoch: "00000000-0000-4000-8000-000000000002", revision: 1)
        let engine = DiffEngine(
            reader: ScreenSequenceReader([before, after]),
            fps: 15,
            idleFps: 5,
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            clock: FakeClock()
        )

        try await confirmation("initial and epoch reset snapshots", expectedCount: 2) { emitted in
            await engine.setOnDiff { _, ops in
                #expect(ops.first == .clear)
                #expect(ops.contains(.row(y: 0, text: before.rows[0])))
                emitted()
            }
            try await engine.tick()
            try await engine.tick()
        }
    }

    @Test func themeDefaultChangeForcesFullReset() throws {
        let before = try Self.screen(terminalBackground: "#101820")
        let after = try Self.screen(terminalBackground: "#111820", revision: 3)
        var state = RowState()

        _ = state.ingest(snapshot: before)
        let ops = state.ingest(snapshot: after)

        #expect(ops.first == .clear)
        #expect(ops.contains(.row(y: 0, text: after.rows[0])))
    }

    @Test func caseOnlyThemeDefaultChangeDoesNotForceReset() throws {
        let before = try Self.screen(terminalForeground: "#abcdef")
        let after = try Self.screen(terminalForeground: "#ABCDEF", revision: 3)
        var state = RowState()

        #expect(before.rows == after.rows)
        #expect(before.snapshotMetadata?.terminalForeground == "#abcdef")
        #expect(after.snapshotMetadata?.terminalForeground == "#abcdef")
        _ = state.ingest(snapshot: before)
        let ops = state.ingest(snapshot: after)
        print("caseOnlyThemeIdentityReset=\(ops.first == .clear) normalized=#abcdef")
        #expect(ops.isEmpty)
    }

    @Test(arguments: [
        (UInt64(2), UInt64(2)),
        (UInt64(2), UInt64(3)),
        (UInt64(3), UInt64(2)),
    ])
    func sourceRevisionAloneAvoidsNeedlessFull(oldRevision: UInt64, newRevision: UInt64) throws {
        let before = try Self.screen(revision: oldRevision)
        let after = try Self.screen(revision: newRevision)
        var state = RowState()

        _ = state.ingest(snapshot: before)
        let ops = state.ingest(snapshot: after)

        #expect(ops.isEmpty)
    }

    @Test(arguments: [
        (UInt64(9), UInt64(9), false),
        (UInt64(9), UInt64(10), true),
        (UInt64(10), UInt64(9), true),
    ])
    func themeRevisionResetSemantics(
        oldRevision: UInt64,
        newRevision: UInt64,
        expectsReset: Bool
    ) throws {
        let before = try Self.screen(themeRevision: oldRevision)
        let after = try Self.screen(revision: 3, themeRevision: newRevision)
        var state = RowState()

        _ = state.ingest(snapshot: before)
        let ops = state.ingest(snapshot: after)

        #expect((ops.first == .clear) == expectsReset)
        if expectsReset {
            #expect(ops.contains(.row(y: 0, text: after.rows[0])))
        } else {
            #expect(ops.isEmpty)
        }
    }

    @Test(arguments: [
        ("00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000001", false),
        ("00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002", true),
        ("00000000-0000-4000-8000-000000000002", "00000000-0000-4000-8000-000000000001", true),
    ])
    func epochResetSemantics(oldEpoch: String, newEpoch: String, expectsReset: Bool) throws {
        let before = try Self.screen(epoch: oldEpoch)
        let after = try Self.screen(epoch: newEpoch, revision: 1)
        var state = RowState()

        _ = state.ingest(snapshot: before)
        let ops = state.ingest(snapshot: after)

        #expect((ops.first == .clear) == expectsReset)
        if expectsReset {
            #expect(ops.contains(.row(y: 0, text: after.rows[0])))
        } else {
            #expect(ops.isEmpty)
        }
    }

    @Test func retainsLatest120StyledScrollbackAndViewportRowsDeterministically() throws {
        let scrollbackSpans: [[String: Any]] = (0..<125).map { row in
            [
                "row": row,
                "column": 0,
                "style_id": 0,
                "text": "history \(row)",
            ]
        }
        let viewportSpans: [[String: Any]] = [
            ["row": 0, "column": 0, "style_id": 0, "text": "viewport 0"],
            ["row": 1, "column": 0, "style_id": 0, "text": "viewport 1"],
        ]
        let first = try Self.screen(
            columns: 16,
            rows: 2,
            cursorRow: 1,
            cursorColumn: 2,
            rowSpans: viewportSpans,
            scrollbackRows: 125,
            scrollbackSpans: scrollbackSpans
        )
        let second = try Self.screen(
            columns: 16,
            rows: 2,
            cursorRow: 1,
            cursorColumn: 2,
            rowSpans: viewportSpans,
            scrollbackRows: 125,
            scrollbackSpans: scrollbackSpans
        )

        #expect(first.rows.count == 120)
        #expect(first.rows == second.rows)
        #expect(Self.visibleText(first.rows[0]) == "history 7")
        #expect(Self.visibleText(first.rows[117]) == "history 124")
        #expect(Self.visibleText(first.rows[118]) == "viewport 0")
        #expect(Self.visibleText(first.rows[119]) == "viewport 1")
        #expect(first.cursor == CursorPos(x: 2, y: 119))
    }

    @Test func viewportLargerThanRetentionStillKeepsExactly120RowsAndTranslatesCursor() throws {
        let screen = try Self.screen(
            columns: 8,
            rows: 121,
            cursorRow: 120,
            cursorColumn: 3,
            rowSpans: [[
                "row": 120,
                "column": 0,
                "style_id": 0,
                "text": "tail",
            ]]
        )

        #expect(screen.rows.count == 120)
        #expect(Self.visibleText(screen.rows[119]) == "tail")
        #expect(screen.cursor == CursorPos(x: 3, y: 119))
        #expect(screen.snapshotMetadata?.viewportRows == 121)
    }

    @Test func invisibleAndRetentionDroppedCursorsUseHiddenSentinel() throws {
        let invisible = try Self.screen(cursorColumn: 3, cursorVisible: false)
        let dropped = try Self.screen(
            columns: 8,
            rows: 121,
            cursorRow: 0,
            cursorColumn: 3,
            rowSpans: [[
                "row": 120,
                "column": 0,
                "style_id": 0,
                "text": "tail",
            ]]
        )

        print("invisibleCursor=\(invisible.cursor.x),\(invisible.cursor.y)")
        print("droppedCursor=\(dropped.cursor.x),\(dropped.cursor.y)")
        #expect(invisible.cursor == .hidden)
        #expect(dropped.cursor == .hidden)
        #expect(invisible.cursor.x < 0)
        #expect(dropped.cursor.x < 0)
    }

    @Test func legacyPlainCursorRemainsAtOrigin() throws {
        let data = Data(#"{"text":"legacy"}"#.utf8)
        let raw = try SharedKitJSON.snakeCaseDecoder.decode(CMUXReadTextRaw.self, from: data)

        #expect(raw.toScreen(rev: 0).cursor == CursorPos(x: 0, y: 0))
    }

    @Test func styledChecksumAndDiffUseTheIdenticalAuthoritativeSnapshot() async throws {
        let screen = try Self.screen(background: "#283228", plainText: "PLAIN FALLBACK")
        let clock = FakeClock()
        clock.advance(by: 5)
        let engine = DiffEngine(
            reader: ScreenSequenceReader([screen]),
            fps: 15,
            idleFps: 5,
            workspaceId: "workspace",
            surfaceId: "surface",
            lines: 120,
            clock: clock
        )
        let expectedHash = ScreenHasher.hash(screen)

        try await confirmation("styled diff and checksum", expectedCount: 2) { emitted in
            await engine.setOnDiff { _, ops in
                let rows = ops.compactMap { op -> String? in
                    guard case .row(_, let text) = op else { return nil }
                    return text
                }
                #expect(rows == screen.rows)
                #expect(rows.allSatisfy { !$0.contains("PLAIN FALLBACK") })
                #expect(rows[0].contains("\u{1B}[38;2;234;234;234;48;2;40;50;40m"))
                emitted()
            }
            await engine.setOnChecksum { hash, _ in
                #expect(hash == expectedHash)
                emitted()
            }
            try await engine.tick()
            #expect(await engine.latestSnapshot == screen)
        }
    }

    @Test(arguments: [
        ("negative scrollback dimensions", -1, "00000000-0000-4000-8000-000000000001"),
        ("malformed render epoch", 0, "not-an-epoch"),
    ])
    func malformedDimensionsAndMetadataReject(
        label: String,
        scrollbackRows: Int,
        epoch: String
    ) throws {
        _ = label
        #expect(throws: (any Error).self) {
            _ = try Self.screen(epoch: epoch, scrollbackRows: scrollbackRows)
        }
    }

    @Test func legacyScreenCodableShapeRemainsExplicitAndCompatible() throws {
        let legacy = Data(#"{"rev":7,"rows":["x"],"cols":1,"cursor":{"x":0,"y":0}}"#.utf8)
        let decoded = try JSONDecoder().decode(Screen.self, from: legacy)
        let styled = try Self.screen()
        let encodedObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(styled)) as? [String: Any]
        )

        #expect(decoded.snapshotMetadata == nil)
        #expect(Set(encodedObject.keys) == ["rev", "rows", "cols", "cursor"])
    }

    static func screen(
        columns: Int = 12,
        rows: Int = 1,
        cursorRow: Int = 0,
        cursorColumn: Int = 0,
        cursorVisible: Bool = true,
        background: String = "#283228",
        terminalForeground: String = "#eaeaea",
        terminalBackground: String = "#101820",
        epoch: String = "00000000-0000-4000-8000-000000000001",
        revision: UInt64 = 2,
        themeRevision: UInt64 = 9,
        rowSpans: [[String: Any]]? = nil,
        scrollbackRows: Int = 0,
        scrollbackSpans: [[String: Any]] = [],
        plainText: String = "legacy"
    ) throws -> Screen {
        let spans = rowSpans ?? [[
            "row": 0,
            "column": 0,
            "style_id": 0,
            "text": "row",
            "cell_width": 3,
        ]]
        let object: [String: Any] = [
            "text": plainText,
            "render_grid": [
                "format": "cmux.render-grid.v1",
                "surface_id": "surface",
                "state_seq": 1,
                "render_epoch": epoch,
                "render_revision": revision,
                "columns": columns,
                "rows": rows,
                "cursor": [
                    "row": cursorRow,
                    "column": cursorColumn,
                    "visible": cursorVisible,
                    "blinking": false,
                    "style": 0,
                ],
                "full": true,
                "styles": [[
                    "id": 0,
                    "foreground": "#eaeaea",
                    "background": background,
                    "foreground_source": "default",
                    "background_source": "rgb",
                ]],
                "row_spans": spans,
                "scrollback_rows": scrollbackRows,
                "scrollback_spans": scrollbackSpans,
                "terminal_foreground": terminalForeground,
                "terminal_background": terminalBackground,
                "terminal_theme_revision": themeRevision,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let raw = try SharedKitJSON.snakeCaseDecoder.decode(CMUXReadTextRaw.self, from: data)
        return raw.toScreen(rev: 0)
    }

    static func visibleText(_ ansi: String) -> String {
        var result = ""
        var iterator = ansi.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" {
                guard iterator.next() == "[" else { continue }
                while let code = iterator.next(), !(0x40...0x7E).contains(code.value) {}
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

private actor ScreenSequenceReader: SurfaceReader {
    private var screens: [Screen]

    init(_ screens: [Screen]) {
        self.screens = screens
    }

    func read(workspaceId: String, surfaceId: String, lines: Int) throws -> Screen {
        try #require(!screens.isEmpty)
        return screens.removeFirst()
    }
}
