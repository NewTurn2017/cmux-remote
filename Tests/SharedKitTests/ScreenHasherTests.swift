import Testing
import Foundation
@testable import SharedKit

@Suite("ScreenHasher")
struct ScreenHasherTests {
    @Test func sameScreenHashesEqual() {
        let a = Screen(rev: 1, rows: ["x","y"], cols: 1, cursor: .init(x: 0, y: 0))
        let b = a
        #expect(ScreenHasher.hash(a) == ScreenHasher.hash(b))
    }

    @Test func cursorChangeChangesHash() {
        let a = Screen(rev: 1, rows: ["x"], cols: 1, cursor: .init(x: 0, y: 0))
        var b = a; b.cursor = .init(x: 1, y: 0)
        #expect(ScreenHasher.hash(a) != ScreenHasher.hash(b))
    }

    @Test func hashIs16HexChars() {
        let h = ScreenHasher.hash(Screen(rev: 0, rows: [], cols: 0, cursor: .init(x: 0, y: 0)))
        #expect(h.count == 16)
        #expect(h.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func rowHashIs16HexChars() {
        let h = ScreenHasher.rowHash("hello world")
        #expect(h.count == 16)
    }
}
