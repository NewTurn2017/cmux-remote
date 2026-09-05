import Foundation
import NIOHTTP1

/// Serves the browser client (`index.html` + assets) straight off disk so the
/// page and the `/v1/*` API share one origin.
///
/// Why this lives in the relay rather than a second web server: the relay has
/// no CORS headers, so a page served from any other origin can't `fetch`
/// `/v1/devices/me/register` at all, and proxying through a helper hides the
/// caller's Tailscale IP from `tailscaled.whois` — which is the only thing
/// authenticating the pairing request. Same origin removes both problems.
///
/// Read-only and unauthenticated by design: pairing has to happen *before* a
/// token exists, and the relay only ever binds behind Tailscale.
public struct StaticFileServer: Sendable {
    /// Fully resolved directory the served paths are confined to.
    public let root: URL

    public init(root: URL) {
        // Resolve once, up front: `/Users/...` is a symlink into
        // `/System/Volumes/Data/Users/...` on modern macOS, so comparing an
        // unresolved root against a resolved candidate would reject every
        // legitimate file.
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Map a request URI to a file under ``root``.
    ///
    /// - `/` serves `index.html`.
    /// - Anything escaping ``root`` (`../`, an absolute path, a symlink out)
    ///   is a 403, never a 404, so a traversal attempt is visible in logs
    ///   instead of blending in with ordinary typos.
    /// - A missing file is a 404; directories are treated as missing rather
    ///   than listed.
    public func response(for uri: String) -> HTTPResponseLite {
        // Strip query + fragment before touching the filesystem — `?v=2`
        // cache-busting is normal for a browser client.
        let rawPath = uri.split(separator: "?", maxSplits: 1).first
            .map(String.init)?
            .split(separator: "#", maxSplits: 1).first
            .map(String.init) ?? "/"
        guard let decoded = rawPath.removingPercentEncoding else {
            return .init(.badRequest)
        }

        let relative = decoded == "/" || decoded.isEmpty
            ? "index.html"
            : String(decoded.drop(while: { $0 == "/" }))
        // NUL bytes truncate C-level path handling; reject rather than
        // normalise them away.
        guard !relative.isEmpty, !relative.contains("\0") else {
            return .init(.forbidden)
        }

        let candidate = root.appendingPathComponent(relative)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard Self.isContained(candidate, in: root) else {
            return .init(.forbidden)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path,
                                             isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let data = try? Data(contentsOf: candidate) else {
            return .init(.notFound)
        }
        return .init(.ok,
                     body: data,
                     contentType: Self.contentType(forPathExtension: candidate.pathExtension),
                     // The client is edited in place and reloaded from a phone
                     // that can't open devtools to force a refresh, so a stale
                     // cached copy is expensive to even notice. It's one small
                     // page off a LAN-speed link — always re-fetch.
                     cacheControl: "no-store")
    }

    /// True when `candidate` is `root` itself or sits beneath it. Compares
    /// path *components* rather than string prefixes so a sibling directory
    /// whose name merely starts with the root's name (`/srv/web-old` next to
    /// `/srv/web`) can't slip through.
    static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootParts = root.pathComponents
        let candidateParts = candidate.pathComponents
        guard candidateParts.count >= rootParts.count else { return false }
        return Array(candidateParts.prefix(rootParts.count)) == rootParts
    }

    /// Browsers refuse to run a module script or apply a stylesheet served
    /// without a matching type, so this map is load-bearing, not cosmetic.
    static func contentType(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "text/javascript; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg":         return "image/svg+xml"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "ico":         return "image/x-icon"
        case "woff2":       return "font/woff2"
        case "woff":        return "font/woff"
        case "txt":         return "text/plain; charset=utf-8"
        default:            return "application/octet-stream"
        }
    }
}
