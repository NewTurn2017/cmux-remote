import Foundation

public enum ANSIColor: Equatable {
    case `default`
    case red, green, yellow, blue, magenta, cyan, white, black
    indirect case bright(ANSIColor)
}

public struct ANSIAttr: Equatable {
    public var fg: ANSIColor
    public var bg: ANSIColor
    public var bold: Bool
    public var underline: Bool

    public static let `default` = ANSIAttr(fg: .default, bg: .default, bold: false, underline: false)

    public init(fg: ANSIColor, bg: ANSIColor, bold: Bool, underline: Bool) {
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.underline = underline
    }
}

public struct ANSICell: Equatable {
    public var character: Character
    public var attr: ANSIAttr

    public init(character: Character, attr: ANSIAttr) {
        self.character = character
        self.attr = attr
    }
}

public enum ANSIParser {
    public static func parse(_ string: String, base: ANSIAttr) -> [ANSICell] {
        var output: [ANSICell] = []
        var attr = base
        var iterator = string.unicodeScalars.makeIterator()

        while let scalar = iterator.next() {
            if scalar == "\u{1B}", let next = iterator.next() {
                guard next == "[" else { continue }
                var args = ""
                while let c = iterator.next() {
                    if c.value >= 0x40 && c.value <= 0x7E {
                        if c == "m" { applySGR(&attr, args: args) }
                        break
                    }
                    args.unicodeScalars.append(c)
                }
            } else {
                output.append(ANSICell(character: Character(scalar), attr: attr))
            }
        }
        return output
    }

    private static func applySGR(_ attr: inout ANSIAttr, args: String) {
        let codes = args.isEmpty ? [0] : args.split(separator: ";").compactMap { Int($0) }
        for code in codes {
            switch code {
            case 0: attr = .default
            case 1: attr.bold = true
            case 4: attr.underline = true
            case 22: attr.bold = false
            case 24: attr.underline = false
            case 30...37: attr.fg = color(for: code - 30)
            case 39: attr.fg = .default
            case 40...47: attr.bg = color(for: code - 40)
            case 49: attr.bg = .default
            case 90...97: attr.fg = .bright(color(for: code - 90))
            default: continue
            }
        }
    }

    private static func color(for code: Int) -> ANSIColor {
        switch code {
        case 0: return .black
        case 1: return .red
        case 2: return .green
        case 3: return .yellow
        case 4: return .blue
        case 5: return .magenta
        case 6: return .cyan
        case 7: return .white
        default: return .default
        }
    }
}
