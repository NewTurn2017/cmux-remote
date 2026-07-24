import Foundation

public enum KeyModifier: String, Codable, Sendable, CaseIterable {
    case ctrl, alt, shift, cmd
    public static let canonicalOrder: [KeyModifier] = [.ctrl, .alt, .shift, .cmd]
}

public enum Key: Sendable, Equatable {
    case enter, tab, esc, up, down, left, right, home, end, pageUp, pageDown, backspace, delete
    case named(String, modifiers: Set<KeyModifier>)

    fileprivate var rawName: String {
        switch self {
        case .enter:     return "enter"
        case .tab:       return "tab"
        case .esc:       return "escape"
        case .up:        return "up"
        case .down:      return "down"
        case .left:      return "left"
        case .right:     return "right"
        case .home:      return "home"
        case .end:       return "end"
        case .pageUp:    return "pgup"
        case .pageDown:  return "pgdn"
        case .backspace: return "backspace"
        case .delete:    return "delete"
        case .named(let n, _): return n
        }
    }

    fileprivate var modifiers: Set<KeyModifier> {
        if case .named(_, let m) = self { return m }
        return []
    }
}

public enum KeyEncoder {
    public static func encode(_ key: Key) -> String {
        let mods = KeyModifier.canonicalOrder.filter { key.modifiers.contains($0) }
        // cmux's control-socket vocabulary uses hyphens (`ctrl-c`), not
        // UI-style pluses (`ctrl+c`). The latter is accepted by neither the
        // terminal key parser nor NSEvent synthesis, so a successful RPC
        // could still be a no-op for Ctrl-C.
        let prefix = mods.map(\.rawValue).joined(separator: "-")
        let name = key.rawName
        return prefix.isEmpty ? name : "\(prefix)-\(name)"
    }

    public static func decode(_ s: String) -> Key? {
        guard !s.isEmpty else { return nil }
        // Decode the old plus-delimited spelling as well so stored drafts or
        // old clients can still be interpreted; all new sends are canonical
        // cmux hyphen-delimited key names.
        let separator: Character = s.contains("+") ? "+" : "-"
        var parts = s.split(separator: separator).map(String.init)
        guard !parts.isEmpty else { return nil }
        let name = parts.removeLast()
        var mods: Set<KeyModifier> = []
        for p in parts {
            guard let m = KeyModifier(rawValue: p) else { return nil }
            mods.insert(m)
        }
        if mods.isEmpty {
            switch name {
            case "enter": return .enter
            case "tab":   return .tab
            case "esc", "escape": return .esc
            case "up":    return .up
            case "down":  return .down
            case "left":  return .left
            case "right": return .right
            case "home":  return .home
            case "end":   return .end
            case "pgup":  return .pageUp
            case "pgdn":  return .pageDown
            case "backspace": return .backspace
            case "delete":    return .delete
            default:      return .named(name, modifiers: [])
            }
        }
        return .named(name, modifiers: mods)
    }
}
