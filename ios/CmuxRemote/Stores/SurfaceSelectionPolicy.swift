import SharedKit

public enum SurfaceRoute: Equatable, Sendable {
    case terminal
    case placeholder
}

enum SurfaceSelectionPolicy {
    /// Relay error code (RPC error and push event) for a non-terminal surface.
    static let notTerminalCode = "surface_not_terminal"

    /// The surface a workspace opens on: the first terminal by index, else the
    /// first surface (which then shows the placeholder card).
    static func initialSurface(in surfaces: [Surface]) -> Surface? {
        let ordered = surfaces.sorted { $0.index < $1.index }
        return ordered.first(where: \.isTerminal) ?? ordered.first
    }

    static func route(for surface: Surface, reportedNotTerminal: Set<String>) -> SurfaceRoute {
        guard surface.isTerminal, !reportedNotTerminal.contains(surface.id) else { return .placeholder }
        return .terminal
    }

    /// Placeholder surfaces open the document viewer only for markdown tabs on a
    /// relay that advertises `surface.document.v1`; everything else keeps the card.
    static func showsDocument(for surface: Surface, documentsEnabled: Bool) -> Bool {
        documentsEnabled && SurfaceKind(surface) == .markdown
    }

    /// Placeholder surfaces open the browser viewer only for browser tabs on a relay that
    /// advertises `surface.browser.v1`; everything else keeps the card.
    static func showsBrowser(for surface: Surface, browsersEnabled: Bool) -> Bool {
        browsersEnabled && SurfaceKind(surface) == .browser
    }

    static func notTerminalSurfaceId(in event: EventFrame) -> String? {
        guard event.category == .surface, event.name == notTerminalCode,
              case .object(let payload) = event.payload,
              case .string(let surfaceId)? = payload["surface_id"]
        else { return nil }
        return surfaceId
    }
}

public enum SurfaceInputError: Error, Equatable, CustomStringConvertible {
    case notTerminal

    public var description: String {
        String(
            localized: "surface.placeholder.input_refused",
            defaultValue: "This tab isn't a terminal, so input wasn't sent."
        )
    }
}
