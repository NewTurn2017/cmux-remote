import SharedKit
import SwiftUI
import UIKit
import XCTest
@testable import CmuxRemote

@MainActor
final class TerminalViewTests: XCTestCase {
    func testIPadUsesReadableDefaultFontWithoutChangingIPhoneDensity() {
        XCTAssertEqual(TerminalLayoutPolicy.defaultFontSize(isPad: true), 11)
        XCTAssertEqual(TerminalLayoutPolicy.defaultFontSize(isPad: false), 8)
    }

    func testBottomScrollPaddingMatchesFiveTerminalRows() {
        XCTAssertEqual(TerminalView.bottomScrollPaddingRows, 5)
        XCTAssertEqual(TerminalView.bottomScrollPadding(lineHeight: 10), 50)
    }

    func testCursorRenderingRequiresBothCoordinatesInBounds() {
        let cases: [(CursorPos, Bool)] = [
            (CursorPos(x: -1, y: -1), false),
            (CursorPos(x: -1, y: 0), false),
            (CursorPos(x: 0, y: -1), false),
            (CursorPos(x: 4, y: 0), false),
            (CursorPos(x: 0, y: 3), false),
            (CursorPos(x: 0, y: 0), true),
            (CursorPos(x: 3, y: 2), true),
        ]

        for (cursor, expected) in cases {
            XCTAssertEqual(
                TerminalView.isCursorRenderable(cursor, columns: 4, rows: 3),
                expected,
                "cursor=(\(cursor.x),\(cursor.y))"
            )
        }
    }

    func testViewportBackgroundIsOpaqueBlack() {
        XCTAssertEqual(rgba(UIColor(CmuxTheme.terminalViewportBackground)), [0, 0, 0, 255])
        XCTAssertNotEqual(rgba(UIColor(CmuxTheme.terminal)), [0, 0, 0, 255])
    }

    func testTerminalCanvasScreenshotPreservesBlackBaseAndStyledRGBBackgroundBlocks() throws {
        var grid = CellGrid(cols: 8, rows: 2)
        grid.replaceRow(
            0,
            raw: "\u{1B}[48;2;125;207;255m  "
                + "\u{1B}[48;2;158;206;106m  "
                + "\u{1B}[48;2;224;175;104m  "
                + "\u{1B}[48;2;157;124;216m  \u{1B}[0m"
        )
        grid.cursor = CursorPos(x: -1, y: -1)
        let metrics = TerminalFontMetrics(fontSize: 8)
        let renderer = ImageRenderer(content: TerminalCanvas(
            grid: grid,
            fontMetrics: metrics,
            leftInset: 16,
            visibleColumns: 8,
            width: 120,
            height: 48
        ))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)

        XCTAssertEqual(try pixelRGBA(in: image, x: 2, y: 2), [0, 0, 0, 255])
        let backgrounds: [([UInt8], Int)] = [
            ([125, 207, 255, 255], 0),
            ([158, 206, 106, 255], 2),
            ([224, 175, 104, 255], 4),
            ([157, 124, 216, 255], 6),
        ]
        for (expected, startColumn) in backgrounds {
            let x = Int(16 + CGFloat(startColumn) * metrics.cellWidth + 1)
            XCTAssertEqual(try pixelRGBA(in: image, x: x, y: 9), expected)
        }
    }

    private func rgba(_ color: UIColor) -> [UInt8] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return [red, green, blue, alpha].map { UInt8(round($0 * 255)) }
    }

    private func pixelRGBA(in image: UIImage, x: Int, y: Int) throws -> [UInt8] {
        let source = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(source.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel
    }
}
