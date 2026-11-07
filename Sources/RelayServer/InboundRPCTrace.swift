import Foundation

/// Timing for one inbound WebSocket text frame, from receipt through the strict FIFO.
///
/// Records only the RPC method name, a short device prefix, and durations. Parameters,
/// results, and terminal contents are never read into the trace, so the log line cannot
/// carry them.
struct InboundRPCTrace: Sendable {
    /// Frames slower than this are always logged, even with tracing off.
    static let slowThresholdMilliseconds = 2_000

    /// Larger frames (chunked uploads) are labelled without parsing their method.
    static let maximumParsedBytes = 64 * 1024

    /// Environment switch that logs every inbound frame.
    static let environmentKey = "CMUX_RELAY_TRACE_RPC"

    let method: String
    let devicePrefix: String
    let receivedAt: ContinuousClock.Instant

    init(text: String, deviceId: String, receivedAt: ContinuousClock.Instant) {
        method = Self.method(of: text)
        devicePrefix = String(deviceId.prefix(8))
        self.receivedAt = receivedAt
    }

    /// Whether every frame should be logged, read once per process.
    static let traceAll: Bool = isEnabled(ProcessInfo.processInfo.environment)

    static func isEnabled(_ environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }

    /// The RPC method name, or a fixed label when the frame has none or is too large.
    static func method(of text: String) -> String {
        guard text.utf8.count <= maximumParsedBytes else { return "<large-frame>" }
        guard let data = text.data(using: .utf8),
              let probe = try? JSONDecoder().decode(MethodProbe.self, from: data)
        else { return "<unparsed>" }
        if let method = probe.method, !method.isEmpty { return method }
        return probe.deviceId == nil ? "<no-method>" : "hello"
    }

    /// The log line for a finished frame, or `nil` when it should not be logged.
    ///
    /// - Parameters:
    ///   - startedAt: When the FIFO began running this frame.
    ///   - finishedAt: When the frame's actions were applied.
    ///   - traceAll: Whether every frame is logged.
    func line(
        startedAt: ContinuousClock.Instant,
        finishedAt: ContinuousClock.Instant,
        traceAll: Bool
    ) -> String? {
        let queued = Self.milliseconds(startedAt - receivedAt)
        let run = Self.milliseconds(finishedAt - startedAt)
        guard traceAll || queued + run >= Self.slowThresholdMilliseconds else { return nil }
        return "rpc method=\(method) device=\(devicePrefix) queued_ms=\(queued) run_ms=\(run)"
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1_000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    private struct MethodProbe: Decodable {
        let method: String?
        let deviceId: String?
    }
}
