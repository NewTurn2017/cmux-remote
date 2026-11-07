import SharedKit

enum SurfaceKind: Equatable {
    case terminal
    case browser
    case markdown
    case other

    init(type: String?) {
        switch type {
        case nil, "terminal": self = .terminal
        case "browser": self = .browser
        case "markdown": self = .markdown
        default: self = .other
        }
    }

    init(_ surface: Surface) {
        self.init(type: surface.type)
    }

    var systemImage: String {
        switch self {
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .markdown: return "doc.richtext"
        case .other: return "doc"
        }
    }

    var identifierSuffix: String {
        switch self {
        case .terminal: return "terminal"
        case .browser: return "browser"
        case .markdown: return "markdown"
        case .other: return "other"
        }
    }

    var accessibilityName: String {
        switch self {
        case .terminal:
            return String(localized: "surface.kind.terminal", defaultValue: "Terminal")
        case .browser:
            return String(localized: "surface.kind.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "surface.kind.markdown", defaultValue: "Markdown")
        case .other:
            return String(localized: "surface.kind.other", defaultValue: "Other tab")
        }
    }
}
