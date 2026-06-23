import NIOCore
import NIOPosix
import Foundation

public enum UnixSocketChannelError: Error, Equatable {
    case socketMissing(String)
    case connectFailed(String)
}

/// Default cmux socket location on macOS.
///
/// Resolution order:
/// 1. `CMUX_SOCKET_PATH`
/// 2. deprecated `CMUX_SOCKET`
/// 3. cmux's fixed `/tmp/cmux-last-socket-path` marker, when it points at an
///    existing socket
/// 4. the XDG state marker `$XDG_STATE_HOME/cmux/last-socket-path`
///    (default `~/.local/state/cmux/last-socket-path`)
/// 5. the legacy `~/Library/Application Support/cmux/last-socket-path` marker
/// 6. the `~/.local/state/cmux/cmux.sock` fallback
///
/// Modern cmux rotates its socket (e.g. `cmux-501.sock`) and, as of the 1.0.5
/// generation, moved its state from `~/Library/Application Support/cmux` to the
/// XDG state dir `~/.local/state/cmux`, publishing the live path through both a
/// fixed `/tmp/cmux-last-socket-path` marker and a per-state-dir marker.
/// Following the markers newest-convention-first keeps long-running relay
/// installs from being pinned to a stale socket after cmux updates or restarts,
/// while the legacy marker keeps older cmux builds working.
public func cmuxSocketPath(
    _ env: [String: String] = ProcessInfo.processInfo.environment,
    appSupportDirectory: URL? = nil,
    stateDirectory: URL? = nil,
    tmpMarkerPath: String = "/tmp/cmux-last-socket-path",
    fileManager: FileManager = .default
) -> String {
    if let p = env["CMUX_SOCKET_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return p }
    if let p = env["CMUX_SOCKET"]?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return p }

    let stateCmuxDirectory = (stateDirectory ?? defaultStateDirectory(env))
        .appendingPathComponent("cmux", isDirectory: true)
    let legacyCmuxDirectory = (appSupportDirectory ?? defaultAppSupportDirectory(env))
        .appendingPathComponent("cmux", isDirectory: true)

    // Follow whichever marker points at a socket that exists, newest cmux
    // convention first, so an update that rotates the socket path is picked up
    // automatically without re-pinning CMUX_SOCKET_PATH.
    let markers = [
        tmpMarkerPath,
        stateCmuxDirectory.appendingPathComponent("last-socket-path", isDirectory: false).path,
        legacyCmuxDirectory.appendingPathComponent("last-socket-path", isDirectory: false).path,
    ]
    for marker in markers {
        if let socket = socketFromMarker(marker, fileManager: fileManager) {
            return socket
        }
    }

    return stateCmuxDirectory.appendingPathComponent("cmux.sock", isDirectory: false).path
}

/// Reads a cmux `last-socket-path` marker file and returns the socket path it
/// names only when that path currently exists, so stale markers are skipped.
private func socketFromMarker(_ markerPath: String, fileManager: FileManager) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: markerPath)),
          let raw = String(data: data, encoding: .utf8)
    else {
        return nil
    }
    let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty, fileManager.fileExists(atPath: candidate) else { return nil }
    return candidate
}

private func defaultStateDirectory(_ env: [String: String]) -> URL {
    if let xdg = env["XDG_STATE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdg.isEmpty {
        return URL(fileURLWithPath: xdg)
    }
    let home = env["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = (home?.isEmpty == false) ? home! : NSHomeDirectory()
    return URL(fileURLWithPath: base)
        .appendingPathComponent(".local", isDirectory: true)
        .appendingPathComponent("state", isDirectory: true)
}

private func defaultAppSupportDirectory(_ env: [String: String]) -> URL {
    if let home = env["HOME"], !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }
    if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        return dir
    }
    return URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
}

/// Resolves the password used by cmux `socketControlMode=password`.
///
/// Resolution order (mirrors ``cmuxSocketPath`` so the relay tracks cmux's
/// own state-dir migrations without re-pinning):
/// 1. `CMUX_SOCKET_PASSWORD` (matches `cmux --help` precedence)
/// 2. `$XDG_STATE_HOME/cmux/socket-control-password` (default
///    `~/.local/state/cmux/socket-control-password`) — written by cmux
///    0.64.16+ when `automation.socketControlMode = "password"`
/// 3. legacy `~/Library/Application Support/cmux/socket-control-password`
///    — older cmux releases
///
/// Each tier checks for a non-empty trimmed value; an empty file or env var
/// is treated as "not set" so a partially-staged install falls through to
/// the next tier instead of authenticating with whitespace.
public func cmuxSocketPassword(
    _ env: [String: String] = ProcessInfo.processInfo.environment,
    stateDirectory: URL? = nil,
    appSupportDirectory: URL? = nil,
    fileManager: FileManager = .default
) -> String? {
    if let p = normalizedSocketPassword(env["CMUX_SOCKET_PASSWORD"]) {
        return p
    }

    let stateCmuxDirectory = (stateDirectory ?? defaultStateDirectory(env))
        .appendingPathComponent("cmux", isDirectory: true)
    if let p = passwordFromFile(
        at: stateCmuxDirectory.appendingPathComponent("socket-control-password", isDirectory: false),
        fileManager: fileManager
    ) {
        return p
    }

    let legacyCmuxDirectory: URL?
    if let appSupportDirectory {
        legacyCmuxDirectory = appSupportDirectory.appendingPathComponent("cmux", isDirectory: true)
    } else if let dir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        legacyCmuxDirectory = dir.appendingPathComponent("cmux", isDirectory: true)
    } else {
        legacyCmuxDirectory = nil
    }
    if let dir = legacyCmuxDirectory,
       let p = passwordFromFile(
           at: dir.appendingPathComponent("socket-control-password", isDirectory: false),
           fileManager: fileManager
       )
    {
        return p
    }

    return nil
}

private func passwordFromFile(at url: URL, fileManager: FileManager) -> String? {
    guard fileManager.fileExists(atPath: url.path),
          let data = try? Data(contentsOf: url),
          let raw = String(data: data, encoding: .utf8)
    else { return nil }
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
