/// Deterministic write failure used by output-pump tests.
enum ControllableWebSocketOutputError: Error {
    case failed
}
