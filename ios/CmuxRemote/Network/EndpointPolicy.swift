import Foundation

public enum ConnectionMode: String, CaseIterable, Identifiable, Sendable {
    case direct
    case broker

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .direct: return L10n.string("DIRECT")
        case .broker: return L10n.string("SERVER")
        }
    }
}

public struct RelayEndpoint: Equatable, Sendable {
    public let mode: ConnectionMode
    public let host: String
    public let port: Int
    public let scheme: String
    public let brokerBaseURL: String
    public let relayId: String

    public static func direct(host: String, port: Int, scheme: String = "http") -> Self {
        .init(
            mode: .direct,
            host: host,
            port: port,
            scheme: scheme,
            brokerBaseURL: "",
            relayId: ""
        )
    }

    public static func broker(baseURL: String, relayId: String) -> Self {
        .init(
            mode: .broker,
            host: "",
            port: 0,
            scheme: "",
            brokerBaseURL: baseURL,
            relayId: relayId
        )
    }

    public func validate() throws {
        switch mode {
        case .direct:
            guard EndpointPolicy.isAllowedRelayHost(host) else { throw AuthError.disallowedHost }
            guard (1...65535).contains(port), ["http", "https"].contains(scheme.lowercased()) else {
                throw AuthError.invalidURL
            }
        case .broker:
            _ = try brokerComponents(webSocket: false, path: "/v1/health")
            guard !relayId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AuthError.missingRelayId
            }
        }
    }

    public func registrationURL() throws -> URL {
        switch mode {
        case .direct:
            try validate()
            guard let url = URL(string: "\(scheme)://\(normalizedHost):\(port)/v1/devices/me/register") else {
                throw AuthError.invalidURL
            }
            return url
        case .broker:
            try validate()
            return try brokerComponents(webSocket: false, path: "/v1/devices/me/register")
        }
    }

    public func apnsURL() throws -> URL {
        switch mode {
        case .direct:
            try validate()
            guard let url = URL(string: "\(scheme)://\(normalizedHost):\(port)/v1/devices/me/apns") else {
                throw AuthError.invalidURL
            }
            return url
        case .broker:
            try validate()
            return try brokerComponents(
                webSocket: false,
                path: "/v1/devices/me/apns",
                queryItems: [URLQueryItem(name: "relay_id", value: normalizedRelayId)]
            )
        }
    }

    public func webSocketURL() throws -> URL {
        switch mode {
        case .direct:
            try validate()
            let wsScheme = scheme.lowercased() == "https" ? "wss" : "ws"
            guard let url = URL(string: "\(wsScheme)://\(normalizedHost):\(port)/v1/ws") else {
                throw AuthError.invalidURL
            }
            return url
        case .broker:
            try validate()
            return try brokerComponents(
                webSocket: true,
                path: "/v1/ws",
                queryItems: [URLQueryItem(name: "relay_id", value: normalizedRelayId)]
            )
        }
    }

    public func credentialIdentity() throws -> String {
        try validate()
        switch mode {
        case .direct:
            return "direct|\(scheme.lowercased())://\(normalizedHost):\(port)"
        case .broker:
            let healthURL = try brokerComponents(webSocket: false, path: "/v1/health")
            var components = URLComponents(url: healthURL, resolvingAgainstBaseURL: false)
            let suffix = "/v1/health"
            if components?.path.hasSuffix(suffix) == true {
                components?.path.removeLast(suffix.count)
            }
            return "broker|\(components?.url?.absoluteString ?? brokerBaseURL)|\(normalizedRelayId)"
        }
    }

    public var legacyHost: String? {
        mode == .direct ? normalizedHost : nil
    }

    private var normalizedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var normalizedRelayId: String {
        relayId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func brokerComponents(
        webSocket: Bool,
        path: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        let raw = brokerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.queryItems?.isEmpty != false
        else { throw AuthError.invalidURL }

        let local = EndpointPolicy.isLoopbackHost(host)
        switch components.scheme?.lowercased() {
        case "https": components.scheme = webSocket ? "wss" : "https"
        case "wss": components.scheme = webSocket ? "wss" : "https"
        case "http" where local: components.scheme = webSocket ? "ws" : "http"
        case "ws" where local: components.scheme = webSocket ? "ws" : "http"
        default: throw AuthError.insecureBrokerURL
        }

        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw AuthError.invalidURL }
        return url
    }
}

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

    public static func isAllowedBrokerURL(_ value: String) -> Bool {
        let endpoint = RelayEndpoint.broker(baseURL: value, relayId: "policy-check")
        return (try? endpoint.validate()) != nil
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
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
