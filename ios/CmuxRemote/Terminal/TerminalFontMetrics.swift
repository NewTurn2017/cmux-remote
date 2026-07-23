import CoreText
import SwiftUI
import UIKit

struct TerminalFontMetrics {
    let fontSize: CGFloat
    let cellWidth: CGFloat
    let lineHeight: CGFloat

    private let regularFont: Font
    private let boldFont: Font

    init(fontSize: CGFloat) {
        let bundledRegular = UIFont(name: "GeistMono-Regular", size: fontSize)
        let bundledBold = UIFont(name: "GeistMono-Bold", size: fontSize)
        let usesBundledFonts = bundledRegular != nil && bundledBold != nil
        let regular = bundledRegular
            ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let bold = bundledBold
            ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)

        self.fontSize = fontSize
        self.cellWidth = max(
            Self.advance(of: 48, in: regular),
            Self.advance(of: 48, in: bold)
        )
        self.lineHeight = ceil(max(regular.lineHeight, bold.lineHeight)) + 2
        if usesBundledFonts {
            self.regularFont = .custom(regular.fontName, fixedSize: fontSize)
            self.boldFont = .custom(bold.fontName, fixedSize: fontSize)
        } else {
            self.regularFont = .system(
                size: fontSize,
                weight: .regular,
                design: .monospaced
            )
            self.boldFont = .system(
                size: fontSize,
                weight: .bold,
                design: .monospaced
            )
        }
    }

    func font(bold: Bool) -> Font {
        bold ? boldFont : regularFont
    }

    private static func advance(of character: UniChar, in font: UIFont) -> CGFloat {
        let coreTextFont = CTFontCreateWithName(
            font.fontName as CFString,
            font.pointSize,
            nil
        )
        var character = character
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(coreTextFont, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(
            coreTextFont,
            .horizontal,
            &glyph,
            &advance,
            1
        )
        return advance.width
    }
}
