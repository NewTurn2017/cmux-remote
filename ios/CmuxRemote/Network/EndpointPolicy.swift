import Foundation

public enum EndpointPolicy {
    public static func isAllowedRelayHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        if trimmed == "localhost" || trimmed == "127.0.0.1" { return true }
        if trimmed.hasSuffix(".ts.net") { return true }
        if let ipv4 = IPv4(trimmed) {
            return ipv4.octets[0] == 100 && (64...127).contains(ipv4.octets[1])
        }
        return false
    }
}

private struct IPv4 {
    let octets: [Int]

    init?(_ value: String) {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        self.octets = octets
    }
}
