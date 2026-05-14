import Foundation

enum TerminalCellWidth {
    static func columns<S: Sequence<ANSICell>>(for row: S) -> Int {
        row.reduce(0) { $0 + columns(for: $1.character) }
    }

    static func columns(for character: Character) -> Int {
        guard !character.unicodeScalars.isEmpty else { return 0 }
        if character.unicodeScalars.allSatisfy(isZeroWidth) { return 0 }
        if character.unicodeScalars.contains(where: isWide) { return 2 }
        return 1
    }

    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return true
        default:
            return false
        }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        switch value {
        case 0x1100...0x115F, // Hangul Jamo init. consonants
             0x2329...0x232A,
             0x2E80...0xA4CF, // CJK radicals, kana, bopomofo, compatibility, Yi
             0xAC00...0xD7A3, // Hangul syllables
             0xF900...0xFAFF, // CJK compatibility ideographs
             0xFE10...0xFE19,
             0xFE30...0xFE6F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6,
             0x2600...0x27BF, // miscellaneous symbols rendered wide with emoji presentation
             0x1F300...0x1FAFF, // emoji and symbols commonly rendered double-width in terminals
             0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
