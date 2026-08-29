@_spi(RelayServer) import RelayCore

/// Creates and detaches the relay session owned by one WebSocket connection.
protocol WebSocketSessionManaging: Sendable {
    func attachForBoundedOutputEvents(
        deviceId: String,
        sendOutputEvent: @escaping @Sendable (SessionOutboundEvent) -> Void
    ) async throws -> Session

    func detach(session: Session) async
}

extension SessionManager: WebSocketSessionManaging {}
