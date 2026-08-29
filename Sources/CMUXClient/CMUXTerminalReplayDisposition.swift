import Foundation

/// Classifies a replay identity before screen conversion.
enum CMUXTerminalReplayDisposition: Equatable, Sendable {
    case accept
    case unchanged
    case ignored(CMUXTerminalReplayIgnoreReason)
}
