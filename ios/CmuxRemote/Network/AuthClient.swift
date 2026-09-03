import Foundation

public struct HTTPClientResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol HTTPClientFacade: Sendable {
    func request(_ request: URLRequest) async throws -> HTTPClientResponse
}

public final class URLSessionHTTP: HTTPClientFacade, @unchecked Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func request(_ request: URLRequest) async throws -> HTTPClientResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.invalidHTTPResponse
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let name = entry.key as? String else { return }
            result[name] = String(describing: entry.value)
        }
        return HTTPClientResponse(
            data: data,
            statusCode: http.statusCode,
            headers: headers
        )
    }
}

public struct AuthCredentials: Equatable, Sendable {
    public let deviceId: String
    public let bearer: String
}

public final class AuthClient: @unchecked Sendable {
    public let host: String
    public let port: Int
    public let keychain: Keychain
    public let http: any HTTPClientFacade
    public let scheme: String

    public init(
        host: String,
        port: Int,
        keychain: Keychain,
        http: any HTTPClientFacade,
        scheme: String = "http"
    ) {
        self.host = host
        self.port = port
        self.keychain = keychain
        self.http = http
        self.scheme = scheme
    }

    public func prepareCredentials() async throws -> AuthCredentials {
        guard EndpointPolicy.isAllowedRelayHost(host) else {
            throw AuthError.disallowedHost
        }
        if let storedHost = try keychain.get("relay_host"), storedHost != host {
            try keychain.wipe()
        }
        if let stored = try storedCredentials(), try keychain.get("relay_host") == host {
            return try await validate(stored)
        }
        return try await register()
    }

    public func validateStoredCredentials() async throws -> AuthCredentials {
        guard let credentials = try storedCredentials(),
              try keychain.get("relay_host") == host else {
            throw AuthError.missingBearer
        }
        return try await validate(credentials)
    }

    public func registerIfNeeded() async throws {
        _ = try await prepareCredentials()
    }

    public func registerAPNsTokenHex(
        _ tokenHex: String,
        environment: APNsRegistrationEnvironment
    ) async throws {
        guard EndpointPolicy.isAllowedRelayHost(host) else { throw AuthError.disallowedHost }
        guard !tokenHex.isEmpty else { throw AuthError.invalidAPNsToken }
        let credentials = try await validateStoredCredentials()
        var request = try makeRequest(path: "/v1/devices/me/apns", method: "POST")
        request.setValue("Bearer \(credentials.bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(APNsRegistrationRequest(
            apnsToken: tokenHex,
            env: environment.rawValue
        ))
        let response = try await http.request(request)
        guard response.statusCode == 204 else {
            throw classifiedError(response)
        }
    }

    public func wipe() throws {
        try keychain.delete("device_id")
        try keychain.delete("bearer")
    }

    private func register() async throws -> AuthCredentials {
        let response = try await http.request(
            try makeRequest(path: "/v1/devices/me/register", method: "POST")
        )
        guard response.statusCode == 200 else { throw classifiedError(response) }
        let payload: RegisterResponse
        do {
            payload = try JSONDecoder().decode(RegisterResponse.self, from: response.data)
        } catch {
            throw AuthError.invalidRelayResponse
        }
        try keychain.set(payload.deviceId, for: "device_id")
        try keychain.set(payload.token, for: "bearer")
        try keychain.set(host, for: "relay_host")
        return AuthCredentials(deviceId: payload.deviceId, bearer: payload.token)
    }

    private func validate(_ credentials: AuthCredentials) async throws -> AuthCredentials {
        var request = try makeRequest(path: "/v1/devices/me", method: "GET")
        request.setValue("Bearer \(credentials.bearer)", forHTTPHeaderField: "Authorization")
        let response = try await http.request(request)
        switch response.statusCode {
        case 200:
            let payload: DeviceStatusResponse
            do {
                payload = try JSONDecoder().decode(DeviceStatusResponse.self, from: response.data)
            } catch {
                throw AuthError.invalidRelayResponse
            }
            if payload.deviceId != credentials.deviceId {
                try keychain.set(payload.deviceId, for: "device_id")
            }
            return AuthCredentials(deviceId: payload.deviceId, bearer: credentials.bearer)
        case 401:
            throw AuthError.pairingRemoved
        case 404:
            // Upgrade compatibility: relays before this endpoint still accept
            // the bearer on WebSocket. The next relay install enables preflight.
            return credentials
        default:
            throw classifiedError(response)
        }
    }

    private func storedCredentials() throws -> AuthCredentials? {
        guard let bearer = try keychain.get("bearer"),
              let deviceId = try keychain.get("device_id") else { return nil }
        return AuthCredentials(deviceId: deviceId, bearer: bearer)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: "\(scheme)://\(host):\(port)\(path)") else {
            throw AuthError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private func classifiedError(_ response: HTTPClientResponse) -> AuthError {
        switch response.statusCode {
        case 403:
            return .registrationDenied
        case 503:
            let retryAfter = response.header("Retry-After").flatMap(TimeInterval.init) ?? 5
            return .relayUnavailable(status: 503, retryAfter: retryAfter)
        case 500...599:
            return .relayUnavailable(status: response.statusCode, retryAfter: nil)
        default:
            return .relayRejected(response.statusCode)
        }
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

private struct DeviceStatusResponse: Decodable {
    let deviceId: String
    enum CodingKeys: String, CodingKey { case deviceId = "device_id" }
}

private struct APNsRegistrationRequest: Encodable {
    let apnsToken: String
    let env: String

    enum CodingKeys: String, CodingKey {
        case apnsToken = "apns_token"
        case env
    }
}

public enum APNsRegistrationEnvironment: String, Codable, Sendable, Equatable {
    case sandbox
    case prod
}

public enum AuthError: Error, Equatable {
    case invalidURL
    case invalidHTTPResponse
    case invalidRelayResponse
    case missingHost
    case disallowedHost
    case missingBearer
    case invalidAPNsToken
    case pairingRemoved
    case registrationDenied
    case relayUnavailable(status: Int, retryAfter: TimeInterval?)
    case relayRejected(Int)
    case transport(String)
}
