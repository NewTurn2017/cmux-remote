import NIOCore
import NIOPosix
import Foundation

public enum UnixSocketChannelError: Error, Equatable {
    case socketMissing(String)
    case connectFailed(String)
}

/// Default cmux socket location on macOS. Honours `CMUX_SOCKET_PATH` (and the
/// deprecated `CMUX_SOCKET` alias) and falls back to the per-user Application
/// Support path the cmux app writes to.
public func cmuxSocketPath(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    if let p = env["CMUX_SOCKET_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return p }
    if let p = env["CMUX_SOCKET"]?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return p }
    let home = env["HOME"] ?? NSHomeDirectory()
    return "\(home)/Library/Application Support/cmux/cmux.sock"
}

/// Connects to a Unix-domain socket and installs the JSON line framer.
public struct UnixSocketChannel {
    public let path: String
    public let group: EventLoopGroup
    public init(path: String, group: EventLoopGroup) { self.path = path; self.group = group }

    public func connect(handler: @escaping @Sendable (Channel) -> EventLoopFuture<Void>)
        async throws -> Channel
    {
        guard FileManager.default.fileExists(atPath: path) else {
            throw UnixSocketChannelError.socketMissing(path)
        }
        let bs = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    LineFrameDecoder(),
                    LineFrameEncoder(),
                ]).flatMap { handler(channel) }
            }
        do {
            return try await bs.connect(unixDomainSocketPath: path).get()
        } catch {
            throw UnixSocketChannelError.connectFailed(String(describing: error))
        }
    }
}
