import NIOHTTP1

/// Browser-origin guard for every HTTP route and the WebSocket upgrade.
///
/// Authentication trusts the Tailscale identity behind the source IP, so a
/// web page running in a browser on a paired device arrives with that
/// device's identity. Two attacks follow from that:
/// - a cross-site `no-cors` POST to `/v1/devices/me/register` replaces the
///   device's bearer (forced logout);
/// - DNS rebinding makes an attacker hostname resolve to the relay, so the
///   page becomes same-origin and can read a fresh bearer.
///
/// Native clients send no `Origin` and reach the relay by Tailscale IP,
/// MagicDNS name or loopback (see the iOS `EndpointPolicy`), so they pass.
enum RequestOriginPolicy {
    static func allows(_ headers: HTTPHeaders) -> Bool {
        let host = headers.first(name: "Host")
        if let host, !isTrustedHost(hostName(fromAuthority: host)) {
            return false
        }
        guard let origin = headers.first(name: "Origin") else { return true }
        // A browser caller must be same-origin with a trusted Host.
        guard let host, let originAuthority = authority(fromOrigin: origin) else {
            return false
        }
        return originAuthority.lowercased() == host.lowercased()
    }

    /// Hostnames an attacker cannot point at the relay: IP literals,
    /// loopback, Tailscale MagicDNS (`*.ts.net`) and single-label names.
    static func isTrustedHost(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name == "localhost" || name.contains(":") { return true }
        if name.hasSuffix(".ts.net") || !name.contains(".") { return true }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count == 4 && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 3 && label.allSatisfy(\.isASCIIDigit)
        }
    }

    /// `"[fd7a::1]:4399"` → `"fd7a::1"`, `"Mac.tail1.ts.net.:4399"` →
    /// `"mac.tail1.ts.net"`.
    static func hostName(fromAuthority authority: String) -> String {
        var value = authority.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return "" }
            return String(value[value.index(after: value.startIndex)..<close])
        }
        if let colon = value.firstIndex(of: ":") {
            value = String(value[..<colon])
        }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    /// `"http://100.64.0.1:4399"` → `"100.64.0.1:4399"`; `"null"` → nil.
    static func authority(fromOrigin origin: String) -> String? {
        guard let range = origin.range(of: "://") else { return nil }
        let authority = origin[range.upperBound...]
        guard !authority.isEmpty, !authority.contains("/") else { return nil }
        return String(authority)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
