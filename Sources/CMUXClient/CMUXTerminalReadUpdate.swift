import Foundation
import SharedKit

/// Carries a newly decoded terminal snapshot and its source identity.
public struct CMUXTerminalReadUpdate: Equatable, Sendable {
    /// The authoritative terminal snapshot.
    public let screen: Screen

    /// The daemon API that produced ``screen``.
    public let sourceMode: CMUXTerminalSourceMode

    /// The replay identity when ``sourceMode`` is ``CMUXTerminalSourceMode/renderGrid``.
    public let replayIdentity: CMUXTerminalReplayIdentity?

    init(
        screen: Screen,
        sourceMode: CMUXTerminalSourceMode,
        replayIdentity: CMUXTerminalReplayIdentity?
    ) {
        self.screen = screen
        self.sourceMode = sourceMode
        self.replayIdentity = replayIdentity
    }
}
