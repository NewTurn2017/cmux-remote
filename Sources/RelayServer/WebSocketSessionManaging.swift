@_spi(RelayServer) import RelayCore

/// Creates and detaches relay sessions for one WebSocket handler lifecycle.
protocol WebSocketSessionManaging: Sendable {
    func attachForBoundedOutputEvents(
        deviceId: String,
        sendOutputEvent: @escaping @Sendable (SessionOutboundEvent) -> Void
    ) async throws -> Session

    func detach(session: Session) async
}

extension SessionManager: WebSocketSessionManaging {}
