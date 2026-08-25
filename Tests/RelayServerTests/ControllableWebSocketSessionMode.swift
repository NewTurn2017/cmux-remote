/// Controls one fake WebSocket session-attachment attempt.
enum ControllableWebSocketSessionMode: Sendable {
    case immediate
    case suspended
    case failure
}
