import Foundation
import SharedKit

/// Carries a session push frame plus the authoritative full state needed for safe coalescing.
///
/// Relay transports may replace queued terminal frames with ``recoveryFull`` under
/// backpressure. Critical frames never carry a replacement and must remain ordered.
public struct SessionOutboundFrame: Sendable, Equatable {
    /// The established push frame sent when no coalescing is necessary.
    public let frame: PushFrame

    /// The latest authoritative full frame for the same terminal state, when applicable.
    public let recoveryFull: ScreenFull?

    /// Subscription generation used to distinguish revision resets after reconnect.
    public let streamIdentity: UUID?

    /// Creates an outbound frame with optional terminal recovery state.
    ///
    /// - Parameters:
    ///   - frame: Established wire frame to send.
    ///   - recoveryFull: Full replacement for terminal coalescing, or `nil` for critical output.
    ///   - streamIdentity: Stable subscription generation for revision ordering.
    public init(
        frame: PushFrame,
        recoveryFull: ScreenFull? = nil,
        streamIdentity: UUID? = nil
    ) {
        self.frame = frame
        self.recoveryFull = recoveryFull
        self.streamIdentity = streamIdentity
    }

    /// Surface identifier when this is a coalescible terminal frame.
    public var terminalSurfaceId: String? {
        recoveryFull?.surfaceId
    }

    /// Delivery revision represented by this frame.
    public var revision: Int? {
        switch frame {
        case .screenFull(let full):
            return full.rev
        case .screenDiff(let diff):
            return diff.rev
        case .screenChecksum(let checksum):
            return checksum.rev
        case .event, .ping, .pong:
            return nil
        }
    }
}
