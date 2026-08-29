import CoreGraphics
import Testing
@testable import CmuxRemote

@Suite("TerminalSelectionGeometryTests")
struct TerminalSelectionGeometryTests {
    @Test func defaultCanvasOriginAndExactCellEdgesUseFloorBeforeConversion() throws {
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 12)
        let snapshot = snapshot(["ABC", "DEF"])

        #expect(geometry.strictPosition(at: CGPoint(x: 16, y: 8), in: snapshot) == position(0, 0))
        #expect(geometry.strictPosition(at: CGPoint(x: 23.999, y: 19.999), in: snapshot) == position(0, 0))
        #expect(geometry.strictPosition(at: CGPoint(x: 24, y: 8), in: snapshot) == position(0, 1))
        #expect(geometry.strictPosition(at: CGPoint(x: 16, y: 20), in: snapshot) == position(1, 0))
        #expect(geometry.strictPosition(at: CGPoint(x: 15.999, y: 8), in: snapshot) == nil)
        #expect(geometry.strictPosition(at: CGPoint(x: 16, y: 7.999), in: snapshot) == nil)
    }

    @Test func customInsetsAndRuntimeMetricsAreAppliedExactly() {
        let geometry = TerminalGridGeometry(
            origin: CGPoint(x: 20, y: 14),
            cellWidth: 7.5,
            lineHeight: 19
        )
        let snapshot = snapshot(["AB", "CD"])

        #expect(geometry.strictPosition(at: CGPoint(x: 20, y: 14), in: snapshot) == position(0, 0))
        #expect(geometry.strictPosition(at: CGPoint(x: 27.499, y: 32.999), in: snapshot) == position(0, 0))
        #expect(geometry.strictPosition(at: CGPoint(x: 27.5, y: 33), in: snapshot) == position(1, 1))
    }

    @Test func strictTargetsRejectNegativeNonFiniteAndPaddingCoordinates() {
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 12)
        let snapshot = snapshot(["AB", "C"])
        let rejected = [
            CGPoint(x: -1, y: 8),
            CGPoint(x: 16, y: -1),
            CGPoint(x: 32, y: 8),
            CGPoint(x: 24, y: 20),
            CGPoint(x: 16, y: 32),
            CGPoint(x: CGFloat.nan, y: 8),
            CGPoint(x: 16, y: CGFloat.nan),
            CGPoint(x: CGFloat.infinity, y: 8),
            CGPoint(x: 16, y: -CGFloat.infinity),
        ]

        for point in rejected {
            #expect(geometry.strictPosition(at: point, in: snapshot) == nil)
        }
        #expect(TerminalGridGeometry(cellWidth: 0, lineHeight: 12).strictPosition(
            at: CGPoint(x: 16, y: 8),
            in: snapshot
        ) == nil)
        #expect(TerminalGridGeometry(cellWidth: 8, lineHeight: CGFloat.infinity).strictPosition(
            at: CGPoint(x: 16, y: 8),
            in: snapshot
        ) == nil)
    }

    @Test func strictTargetsRejectEmptyRowsWhileDragTargetsClampDeterministically() {
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 12)
        let rows = snapshot(["AB", "", "CD"])

        #expect(geometry.strictPosition(at: CGPoint(x: 16, y: 20), in: rows) == nil)
        #expect(geometry.clampedPosition(at: CGPoint(x: 16, y: 20), in: rows) == position(0, 0))
        #expect(geometry.clampedPosition(at: CGPoint(x: -100, y: -100), in: rows) == position(0, 0))
        #expect(geometry.clampedPosition(at: CGPoint(x: 10_000, y: 10_000), in: rows) == position(2, 1))
        #expect(geometry.clampedPosition(at: CGPoint(x: 16, y: 8), in: snapshot(["", ""])) == nil)
    }

    @Test func strictInitialTargetDiffersFromClampedDragTarget() {
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 12)
        let snapshot = snapshot(["AB"])
        let rightPadding = CGPoint(x: 200, y: 10)
        let leftInset = CGPoint(x: 0, y: 10)
        let bottomPadding = CGPoint(x: 16, y: 200)

        #expect(geometry.strictPosition(at: rightPadding, in: snapshot) == nil)
        #expect(geometry.strictPosition(at: leftInset, in: snapshot) == nil)
        #expect(geometry.strictPosition(at: bottomPadding, in: snapshot) == nil)
        #expect(geometry.clampedPosition(at: rightPadding, in: snapshot) == position(0, 1))
        #expect(geometry.clampedPosition(at: leftInset, in: snapshot) == position(0, 0))
        #expect(geometry.clampedPosition(at: bottomPadding, in: snapshot) == position(0, 0))
    }

    @Test func eitherDisplayColumnOfCJKTargetsTheSameAtomicGlyphPosition() throws {
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 12)
        let snapshot = snapshot(["A한B"])
        let firstWideColumn = try #require(geometry.strictPosition(
            at: CGPoint(x: 24, y: 8),
            in: snapshot
        ))
        let secondWideColumn = try #require(geometry.strictPosition(
            at: CGPoint(x: 32, y: 8),
            in: snapshot
        ))

        #expect(firstWideColumn == position(0, 1))
        #expect(secondWideColumn == firstWideColumn)
    }

    @Test func malformedSnapshotRangesRejectWithoutTrapping() {
        let malformed = TerminalSelectionSnapshot(rows: [
            TerminalSelectionRow(spans: [
                TerminalColumnSpan(columns: 2..<3, text: "B"),
                TerminalColumnSpan(columns: 0..<1, text: "A"),
            ]),
        ])
        let geometry = TerminalGridGeometry(cellWidth: 8, lineHeight: 12)

        #expect(geometry.strictPosition(at: CGPoint(x: 16, y: 8), in: malformed) == nil)
        #expect(geometry.clampedPosition(at: CGPoint(x: 16, y: 8), in: malformed) == nil)
    }

    private func position(_ row: Int, _ column: Int) -> TerminalGridPosition {
        TerminalGridPosition(row: row, column: column)
    }

    private func snapshot(_ rawRows: [String]) -> TerminalSelectionSnapshot {
        var grid = CellGrid(cols: 80, rows: rawRows.count)
        for (index, row) in rawRows.enumerated() {
            grid.replaceRow(index, raw: row)
        }
        return TerminalSelectionSnapshot(renderRows: grid.renderRows)
    }
}
