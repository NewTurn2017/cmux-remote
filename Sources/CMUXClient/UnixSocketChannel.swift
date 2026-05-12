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

/// Resolves the password used by cmux `socketControlMode=password`.
///
/// Order intentionally matches current cmux CLI behavior for non-interactive
/// local automation: `CMUX_SOCKET_PASSWORD` first, then the per-user password
/// file written by cmux Settings. The relay does not put secrets into launchd
/// plists; a launchd-started relay can read the same owner-only file.
public func cmuxSocketPassword(
    _ env: [String: String] = ProcessInfo.processInfo.environment,
    appSupportDirectory: URL? = nil,
    fileManager: FileManager = .default
) -> String? {
    if let p = normalizedSocketPassword(env["CMUX_SOCKET_PASSWORD"]) {
        return p
    }

    guard let appSupportDirectory = appSupportDirectory
        ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
        return nil
    }

    let passwordFile = appSupportDirectory
        .appendingPathComponent("cmux", isDirectory: true)
        .appendingPathComponent("socket-control-password", isDirectory: false)
    guard fileManager.fileExists(atPath: passwordFile.path),
          let data = try? Data(contentsOf: passwordFile),
          let raw = String(data: data, encoding: .utf8)
    else {
        return nil
    }
    return normalizedSocketPassword(raw)
}

private func normalizedSocketPassword(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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
