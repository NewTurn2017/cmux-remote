import Foundation

public enum ANSIColor: Equatable {
    case `default`
    case red, green, yellow, blue, magenta, cyan, white, black
    case indexed(Int)
    case rgb(UInt8, UInt8, UInt8)
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
    public var sourceColumn: Int?
    public var sourceCellWidth: Int?
    public var sourceScalarCount: Int?

    public init(
        character: Character,
        attr: ANSIAttr,
        sourceColumn: Int? = nil,
        sourceCellWidth: Int? = nil,
        sourceScalarCount: Int? = nil
    ) {
        self.character = character
        self.attr = attr
        self.sourceColumn = sourceColumn
        self.sourceCellWidth = sourceCellWidth
        self.sourceScalarCount = sourceScalarCount
    }
}

public enum ANSIParser {
    public static func parse(_ string: String, base: ANSIAttr) -> [ANSICell] {
        var output: [ANSICell] = []
        var attr = base
        var pendingGeometry: (start: Int, column: Int, width: Int, remaining: Int)?
        var iterator = string.unicodeScalars.makeIterator()

        while let scalar = iterator.next() {
            if scalar == "\u{1B}", let next = iterator.next() {
                guard next == "[" else { continue }
                var args = ""
                while let c = iterator.next() {
                    if c.value >= 0x40 && c.value <= 0x7E {
                        if c == "z", let geometry = spanGeometry(from: args) {
                            pendingGeometry = (
                                start: output.count,
                                column: geometry.column,
                                width: geometry.width,
                                remaining: geometry.scalarCount
                            )
                        } else {
                            pendingGeometry = nil
                            if c == "m" {
                                applySGR(&attr, args: args)
                            }
                        }
                        break
                    }
                    args.unicodeScalars.append(c)
                }
            } else {
                output.append(ANSICell(character: Character(scalar), attr: attr))
                if var pending = pendingGeometry {
                    pending.remaining -= 1
                    if pending.remaining == 0 {
                        output[pending.start].sourceColumn = pending.column
                        output[pending.start].sourceCellWidth = pending.width
                        output[pending.start].sourceScalarCount = output.count - pending.start
                        pendingGeometry = nil
                    } else {
                        pendingGeometry = pending
                    }
                }
            }
        }
        return output
    }

    private static func spanGeometry(
        from args: String
    ) -> (column: Int, width: Int, scalarCount: Int)? {
        let fields = args.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 4,
              fields[0] == "?2026",
              let column = Int(fields[1]),
              let width = Int(fields[2]),
              let scalarCount = Int(fields[3]),
              column >= 0,
              width > 0,
              scalarCount > 0,
              column <= Int.max - width
        else { return nil }
        return (column, width, scalarCount)
    }

    private static func applySGR(_ attr: inout ANSIAttr, args: String) {
        let codes = args.isEmpty ? [0] : args.split(separator: ";").compactMap { Int($0) }
        var index = 0
        while index < codes.count {
            let code = codes[index]
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
            case 100...107: attr.bg = .bright(color(for: code - 100))
            case 38:
                if let parsed = extendedColor(from: codes, start: index + 1) {
                    attr.fg = parsed.color
                    index = parsed.nextIndex
                }
            case 48:
                if let parsed = extendedColor(from: codes, start: index + 1) {
                    attr.bg = parsed.color
                    index = parsed.nextIndex
                }
            default: break
            }
            index += 1
        }
    }

    private static func extendedColor(from codes: [Int], start: Int) -> (color: ANSIColor, nextIndex: Int)? {
        guard start < codes.count else { return nil }
        switch codes[start] {
        case 5:
            guard start + 1 < codes.count else { return nil }
            return (.indexed(max(0, min(255, codes[start + 1]))), start + 1)
        case 2:
            guard start + 3 < codes.count else { return nil }
            let r = UInt8(max(0, min(255, codes[start + 1])))
            let g = UInt8(max(0, min(255, codes[start + 2])))
            let b = UInt8(max(0, min(255, codes[start + 3])))
            return (.rgb(r, g, b), start + 3)
        default:
            return nil
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
