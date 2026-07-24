import AsyncHTTPClient
import Crypto
import Foundation
import NIOCore
import SharedKit

public struct APNsPushAlert: Sendable, Equatable {
    public var deviceToken: String
    public var environment: String
    public var notification: NotificationRecord

    public init(deviceToken: String, environment: String, notification: NotificationRecord) {
        self.deviceToken = deviceToken
        self.environment = environment
        self.notification = notification
    }
}

public struct APNsPreparedRequest: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, headers: [String: String], body: Data) {
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct APNsHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data?

    public init(status: Int, headers: [String: String], body: Data?) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public enum APNsSendResult: Sendable, Equatable {
    case disabled
    case delivered(apnsId: String?)
    case invalidToken(reason: String?, apnsId: String?)
    case failed(status: Int, reason: String?, apnsId: String?)
}

public enum APNsProviderError: Error, Sendable, Equatable {
    case disabled
    case invalidDeviceToken
    case invalidEnvironment(String)
    case environmentMismatch(config: String, device: String)
    case invalidURL
    case payloadTooLarge
    case signingFailed
}

public protocol APNsSending: Sendable {
    func send(_ push: APNsPushAlert) async throws -> APNsSendResult
}

public protocol APNsTransport: Sendable {
    func send(_ request: APNsPreparedRequest) async throws -> APNsHTTPResponse
}

public final class APNsHTTPTransport: APNsTransport, @unchecked Sendable {
    private let httpClient: HTTPClient

    public init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    public func send(_ request: APNsPreparedRequest) async throws -> APNsHTTPResponse {
        var outbound = HTTPClientRequest(url: request.url.absoluteString)
        outbound.method = .POST
        for (name, value) in request.headers {
            outbound.headers.add(name: name, value: value)
        }
        var buffer = ByteBufferAllocator().buffer(capacity: request.body.count)
        buffer.writeBytes(request.body)
        outbound.body = .bytes(buffer)

        let response = try await httpClient.execute(outbound, timeout: .seconds(10))
        let body = try await response.body.collect(upTo: 16 * 1024)
        var headers: [String: String] = [:]
        response.headers.forEach { name, value in
            headers[name.lowercased()] = value
        }
        return APNsHTTPResponse(
            status: Int(response.status.code),
            headers: headers,
            body: Data(buffer: body)
        )
    }
}

public final class APNsProviderClient: APNsSending, @unchecked Sendable {
    private struct TokenCache {
        var keyPath: String
        var keyId: String
        var teamId: String
        var issuedAt: Int64
        var token: String
    }

    private let config: @Sendable () -> RelayConfig.APNs
    private let transport: any APNsTransport
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var tokenCache: TokenCache?

    public init(
        config: @escaping @Sendable () -> RelayConfig.APNs,
        transport: any APNsTransport = APNsHTTPTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.transport = transport
        self.now = now
    }

    public func send(_ push: APNsPushAlert) async throws -> APNsSendResult {
        guard isEnabled(config()) else { return .disabled }
        let request = try prepareRequest(push)
        let response = try await transport.send(request)
        if response.isProviderTokenAuthFailure {
            clearTokenCache()
        }
        return map(response)
    }

    public func prepareRequest(_ push: APNsPushAlert) throws -> APNsPreparedRequest {
        let config = config()
        guard isEnabled(config) else { throw APNsProviderError.disabled }
        guard !push.deviceToken.isEmpty else { throw APNsProviderError.invalidDeviceToken }
        guard config.env == "sandbox" || config.env == "prod" else {
            throw APNsProviderError.invalidEnvironment(config.env)
        }
        guard push.environment == config.env else {
            throw APNsProviderError.environmentMismatch(config: config.env, device: push.environment)
        }

        let host = config.env == "prod" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(push.deviceToken)") else {
            throw APNsProviderError.invalidURL
        }
        let token = try providerToken(config: config)
        let body = try payloadData(for: push.notification)
        guard body.count <= 4096 else { throw APNsProviderError.payloadTooLarge }

        return APNsPreparedRequest(
            url: url,
            headers: [
                "authorization": "bearer \(token)",
                "apns-topic": config.topic,
                "apns-push-type": "alert",
                "apns-priority": "10",
                "content-type": "application/json",
            ],
            body: body
        )
    }

    private func isEnabled(_ config: RelayConfig.APNs) -> Bool {
        !config.keyPath.isEmpty
            && !config.keyId.isEmpty
            && !config.teamId.isEmpty
            && !config.topic.isEmpty
    }

    private func providerToken(config: RelayConfig.APNs) throws -> String {
        let issuedAt = Int64(now().timeIntervalSince1970)
        lock.lock()
        if let cached = tokenCache,
           cached.keyPath == config.keyPath,
           cached.keyId == config.keyId,
           cached.teamId == config.teamId,
           issuedAt - cached.issuedAt < 50 * 60
        {
            lock.unlock()
            return cached.token
        }
        lock.unlock()

        do {
            let header = try base64URLEncodedJSON(["alg": "ES256", "kid": config.keyId])
            let payload = try base64URLEncodedJSON(["iss": config.teamId, "iat": issuedAt])
            let signingInput = "\(header).\(payload)"
            let pem = try String(contentsOfFile: config.keyPath, encoding: .utf8)
            let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
            let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
            let token = "\(signingInput).\(base64URLEncode(signature))"

            lock.lock()
            tokenCache = TokenCache(
                keyPath: config.keyPath,
                keyId: config.keyId,
                teamId: config.teamId,
                issuedAt: issuedAt,
                token: token
            )
            lock.unlock()
            return token
        } catch {
            throw APNsProviderError.signingFailed
        }
    }

    private func clearTokenCache() {
        lock.lock()
        tokenCache = nil
        lock.unlock()
    }

    private func base64URLEncodedJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return base64URLEncode(data)
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func payloadData(for notification: NotificationRecord) throws -> Data {
        var payload: [String: Any] = [
            "aps": [
                "alert": [
                    "title": "cmux needs attention",
                    "body": "Open cmux Remote to review this inbox item.",
                ],
                "sound": "default",
                "thread-id": notification.threadId,
            ],
            "workspace_id": notification.workspaceId,
            "notification_id": notification.id,
            "thread_id": notification.threadId,
        ]
        if let surfaceId = notification.surfaceId, !surfaceId.isEmpty {
            payload["surface_id"] = surfaceId
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private func map(_ response: APNsHTTPResponse) -> APNsSendResult {
        let apnsId = response.headers["apns-id"] ?? response.headers["Apns-Id"]
        if response.status == 200 {
            return .delivered(apnsId: apnsId)
        }
        let reason = response.reason
        if response.status == 410
            || reason == "BadDeviceToken"
            || reason == "Unregistered"
            || reason == "DeviceTokenNotForTopic"
        {
            return .invalidToken(reason: reason, apnsId: apnsId)
        }
        return .failed(status: response.status, reason: reason, apnsId: apnsId)
    }
}

private extension APNsHTTPResponse {
    var reason: String? {
        guard let body, !body.isEmpty else { return nil }
        struct ErrorBody: Decodable { let reason: String? }
        guard let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body) else { return nil }
        return decoded.reason
    }

    var isProviderTokenAuthFailure: Bool {
        guard status == 403 else { return false }
        return reason == "ExpiredProviderToken" || reason == "InvalidProviderToken"
    }
}
