/// Monotonic counters for one bounded WebSocket output pump lifecycle.
struct WebSocketOutputPumpMetrics: Equatable, Sendable {
    var maximumQueuedBytes = 0
    var maximumQueuedFrames = 0
    var maximumInFlightWrites = 0
    var maximumTerminalRevisionStates = 0
    var writesStarted = 0
    var writesCompleted = 0
    var fullWrites = 0
    var diffWrites = 0
    var checksumWrites = 0
    var criticalWrites = 0
    var coalescedTerminalFrames = 0
    var staleTerminalFrames = 0
    var discardedFrames = 0
    var writeFailures = 0
    var encodingFailures = 0
}
