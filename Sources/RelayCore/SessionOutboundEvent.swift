import Foundation

/// Carries relay-internal output and terminal-stream lifecycle events to the server transport.
@_spi(RelayServer)
public enum SessionOutboundEvent: Sendable, Equatable {
    /// Delivers one established client push frame with coalescing metadata.
    case frame(SessionOutboundFrame)

    /// Retires one exact surface subscription generation without producing a wire frame.
    case retire(surfaceId: String, streamIdentity: UUID)
}
