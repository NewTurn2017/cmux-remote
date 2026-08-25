/// Bounded exact-event probe failures.
enum RelayServerBoundedStreamError: Error {
    case ended
    case timeout
}
