import Foundation

/// Describes the capabilities and RPC methods advertised by the connected cmux daemon.
public struct CMUXCapabilities: Decodable, Equatable, Sendable {
    /// Capability identifiers advertised by the daemon.
    public let capabilities: [String]

    /// RPC method names accepted by the daemon.
    public let methods: [String]

    /// Whether the daemon advertises the complete verified render-grid replay contract.
    public var supportsVerifiedTerminalReplay: Bool {
        let advertisedCapabilities = Set(capabilities)
        return advertisedCapabilities.isSuperset(of: [
            "terminal.render_grid.v1",
            "terminal.render_grid.verified_replay.v1",
        ]) && methods.contains("terminal.replay")
    }
}
