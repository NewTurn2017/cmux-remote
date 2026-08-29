import Foundation

/// Reports a malformed or internally inconsistent terminal source response.
public enum CMUXTerminalSourceError: Error, Equatable, Sendable {
    /// The capabilities response did not contain the required array fields.
    case malformedCapabilities(String)

    /// The replay payload could not be decoded as the verified contract.
    case malformedReplay(String)

    /// The replay envelope names a surface other than the requested surface.
    case surfaceMismatch(expected: String, received: String)

    /// The replay envelope names a workspace other than the requested workspace.
    case workspaceMismatch(expected: String, received: String)

    /// The replay envelope and render grid disagree about the source surface.
    case renderGridSurfaceMismatch(envelope: String, renderGrid: String)

    /// The replay envelope and render grid disagree about the source sequence.
    case sequenceMismatch(envelope: UInt64, renderGrid: UInt64)

    /// The replay envelope and render grid disagree about terminal geometry.
    case dimensionsMismatch(
        envelopeColumns: Int,
        envelopeRows: Int,
        renderGridColumns: Int,
        renderGridRows: Int
    )

    /// A replay response was not an authoritative full snapshot.
    case nonFullReplay

    /// The replay used an anchor other than the requested viewport anchor.
    case unexpectedAnchor(String)

    /// The verified replay omitted or malformed its producer epoch.
    case invalidEpoch(String)
}
