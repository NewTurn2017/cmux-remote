import Foundation

public protocol HTTPClientFacade: Sendable {
    func request(_ request: URLRequest) async throws -> (Data, Int)
}

public final class URLSessionHTTP: HTTPClientFacade, @unchecked Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func request(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, code)
    }
}

public final class AuthClient: @unchecked Sendable {
    public let endpoint: RelayEndpoint
    public let keychain: Keychain
    public let http: any HTTPClientFacade
    public let pairingCode: String
    public let clientId: String
    public let deviceName: String

    public init(host: String, port: Int, keychain: Keychain, http: any HTTPClientFacade, scheme: String = "http") {
        self.endpoint = .direct(host: host, port: port, scheme: scheme)
        self.keychain = keychain
        self.http = http
        self.pairingCode = ""
        self.clientId = ""
        self.deviceName = ""
    }

    public init(
        endpoint: RelayEndpoint,
        keychain: Keychain,
        http: any HTTPClientFacade,
        pairingCode: String = "",
        clientId: String = "",
        deviceName: String = ""
    ) {
        self.endpoint = endpoint
        self.keychain = keychain
        self.http = http
        self.pairingCode = pairingCode
        self.clientId = clientId
        self.deviceName = deviceName
    }

    public func registerIfNeeded() async throws {
        try endpoint.validate()
        let identity = try endpoint.credentialIdentity()
        if let storedIdentity = try storedCredentialIdentity(currentIdentity: identity),
           storedIdentity != identity {
            try clearCredentials()
        }
        if try keychain.get("bearer") != nil,
           try keychain.get("device_id") != nil,
           try storedCredentialIdentity(currentIdentity: identity) == identity {
            return
        }
        var request = URLRequest(url: try endpoint.registrationURL())
        request.httpMethod = "POST"
        if endpoint.mode == .broker {
            guard !pairingCode.isEmpty else { throw AuthError.missingPairingCode }
            guard !clientId.isEmpty, !deviceName.isEmpty else { throw AuthError.invalidRegistration }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(BrokerRegisterRequest(
                relayId: endpoint.relayId.trimmingCharacters(in: .whitespacesAndNewlines),
                pairingCode: pairingCode,
                clientId: clientId,
                deviceName: deviceName
            ))
        }
        let (data, code) = try await http.request(request)
        guard code == 200 else { throw AuthError.relayRejected(code) }
        let payload = try JSONDecoder().decode(RegisterResponse.self, from: data)
        try keychain.set(payload.deviceId, for: "device_id")
        try keychain.set(payload.token, for: "bearer")
        try keychain.set(identity, for: "relay_endpoint")
        if let host = endpoint.legacyHost { try keychain.set(host, for: "relay_host") }
    }

    public func registerAPNsTokenHex(
        _ tokenHex: String,
        environment: APNsRegistrationEnvironment
    ) async throws {
        try endpoint.validate()
        let identity = try endpoint.credentialIdentity()
        guard !tokenHex.isEmpty else { throw AuthError.invalidAPNsToken }
        guard let bearer = try keychain.get("bearer"),
              try keychain.get("device_id") != nil,
              try storedCredentialIdentity(currentIdentity: identity) == identity
        else {
            throw AuthError.missingBearer
        }
        var request = URLRequest(url: try endpoint.apnsURL())
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(APNsRegistrationRequest(
            apnsToken: tokenHex,
            env: environment.rawValue
        ))
        let (_, code) = try await http.request(request)
        guard code == 204 else { throw AuthError.relayRejected(code) }
    }

    public func wipe() throws {
        try clearCredentials()
    }

    private func storedCredentialIdentity(currentIdentity: String) throws -> String? {
        if let identity = try keychain.get("relay_endpoint") { return identity }
        if endpoint.mode == .direct,
           let legacyHost = try keychain.get("relay_host")?.lowercased(),
           legacyHost == endpoint.legacyHost {
            return currentIdentity
        }
        if let legacyHost = try keychain.get("relay_host") { return "legacy|\(legacyHost)" }
        return nil
    }

    private func clearCredentials() throws {
        try keychain.delete("device_id")
        try keychain.delete("bearer")
        try keychain.delete("relay_host")
        try keychain.delete("relay_endpoint")
    }
}

private struct RegisterResponse: Decodable {
    let deviceId: String
    let token: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case token
    }
}

private struct APNsRegistrationRequest: Encodable {
    let apnsToken: String
    let env: String

    enum CodingKeys: String, CodingKey {
        case apnsToken = "apns_token"
        case env
    }
}

private struct BrokerRegisterRequest: Encodable {
    let relayId: String
    let pairingCode: String
    let clientId: String
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case relayId = "relay_id"
        case pairingCode = "pairing_code"
        case clientId = "client_id"
        case deviceName = "device_name"
    }
}

public enum APNsRegistrationEnvironment: String, Codable, Sendable, Equatable {
    case sandbox
    case prod
}

public enum AuthError: Error, Equatable {
    case invalidURL
    case disallowedHost
    case insecureBrokerURL
    case missingRelayId
    case missingPairingCode
    case invalidRegistration
    case missingBearer
    case invalidAPNsToken
    case relayRejected(Int)
}

extension AuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return L10n.string("Invalid relay URL")
        case .disallowedHost: return L10n.string("Direct mode requires a Tailscale host or 100.64.0.0/10 address")
        case .insecureBrokerURL: return L10n.string("Server mode requires an HTTPS URL")
        case .missingRelayId: return L10n.string("Relay ID is required")
        case .missingPairingCode: return L10n.string("Pairing code is required")
        case .invalidRegistration: return L10n.string("This device could not create a pairing identity")
        case .missingBearer: return L10n.string("This device is not paired")
        case .invalidAPNsToken: return L10n.string("Invalid APNs token")
        case .relayRejected(let code): return L10n.format("Relay rejected the request (HTTP %lld)", code)
        }
    }
}
