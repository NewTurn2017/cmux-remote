import Testing
import SharedKit

@Suite("CursorRenderingTests")
struct CursorRenderingTests {
    @Test(arguments: [
        (CursorPos(x: -1, y: -1), false),
        (CursorPos(x: -1, y: 0), false),
        (CursorPos(x: 0, y: -1), false),
        (CursorPos(x: 4, y: 0), false),
        (CursorPos(x: 0, y: 3), false),
        (CursorPos(x: 0, y: 0), true),
        (CursorPos(x: 3, y: 2), true),
    ])
    func rendererDecision(cursor: CursorPos, expected: Bool) {
        let terminalViewDecision = cursor.isRenderable(columns: 4, rows: 3)
        print("cursor=\(cursor.x),\(cursor.y) rendererDecision=\(terminalViewDecision)")
        #expect(terminalViewDecision == expected)
    }
}
