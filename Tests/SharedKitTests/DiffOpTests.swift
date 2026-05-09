import Testing
import Foundation
@testable import SharedKit

@Suite("DiffOp")
struct DiffOpTests {
    @Test func emptyDiffWhenScreensEqual() {
        let a = Screen(rev: 0, rows: ["one", "two"], cols: 3, cursor: .init(x: 0, y: 0))
        let b = a
        #expect(DiffOp.compute(from: a, to: b) == [])
    }

    @Test func rowDiffPerLine() {
        let a = Screen(rev: 1, rows: ["one", "two", "three"], cols: 5, cursor: .init(x: 0, y: 0))
        var b = a
        b.rows[1] = "TWO"
        b.rev = 2
        let ops = DiffOp.compute(from: a, to: b)
        #expect(ops == [.row(y: 1, text: "TWO")])
    }

    @Test func cursorOnlyDiff() {
        let a = Screen(rev: 1, rows: ["x"], cols: 1, cursor: .init(x: 0, y: 0))
        var b = a
        b.cursor = .init(x: 5, y: 9)
        b.rev = 2
        let ops = DiffOp.compute(from: a, to: b)
        #expect(ops == [.cursor(x: 5, y: 9)])
    }

    @Test func applyIsInverseOfCompute() {
        let a = Screen(rev: 1,
                       rows: ["alpha", "beta", "gamma"],
                       cols: 5,
                       cursor: .init(x: 1, y: 1))
        var b = a
        b.rows[0] = "ALPHA"
        b.rows[2] = "GAMMA"
        b.cursor = .init(x: 4, y: 2)
        b.rev    = 2
        let ops = DiffOp.compute(from: a, to: b)
        var reconstructed = a
        DiffOp.apply(ops, to: &reconstructed)
        reconstructed.rev = b.rev   // rev is metadata; not transported in DiffOp
        #expect(reconstructed == b)
    }

    @Test func diffOpEncodesRowVariant() throws {
        let op: DiffOp = .row(y: 7, text: "$ ls")
        let json = try String(data: JSONEncoder().encode(op), encoding: .utf8)!
        #expect(json.contains("\"op\":\"row\""))
        #expect(json.contains("\"y\":7"))
        #expect(json.contains("\"text\":\"$ ls\""))
    }

    @Test func diffOpEncodesCursorVariant() throws {
        let op: DiffOp = .cursor(x: 0, y: 9)
        let json = try String(data: JSONEncoder().encode(op), encoding: .utf8)!
        #expect(json.contains("\"op\":\"cursor\""))
        #expect(json.contains("\"x\":0"))
        #expect(json.contains("\"y\":9"))
    }
}
