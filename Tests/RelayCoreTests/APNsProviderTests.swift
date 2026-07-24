import Foundation
import XCTest
@testable import RelayCore
@testable import SharedKit

final class APNsProviderTests: XCTestCase {
    func testPrepareRequestBuildsAPNsPostWithJwtHeadersAndPrivacyLimitedPayload() throws {
        let keyURL = try writeTestPrivateKey()
        let config = RelayConfig.APNs(
            keyPath: keyURL.path,
            keyId: "KEY1234567",
            teamId: "TEAM123456",
            topic: "com.genie.CmuxRemote",
            env: "sandbox"
        )
        let client = APNsProviderClient(
            config: { config },
            transport: RecordingAPNsTransport(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let push = APNsPushAlert(
            deviceToken: "abcdef1234",
            environment: "sandbox",
            notification: NotificationRecord(
                id: "n1",
                workspaceId: "w1",
                surfaceId: "s1",
                title: "terminal output SECRET_TOKEN must not be sent",
                subtitle: "workspace",
                body: "terminal output SECRET_TOKEN must not be sent",
                ts: 42,
                threadId: "workspace-w1"
            )
        )

        let request = try client.prepareRequest(push)

        XCTAssertEqual(request.url.absoluteString, "https://api.sandbox.push.apple.com/3/device/abcdef1234")
        XCTAssertEqual(request.headers["apns-topic"], "com.genie.CmuxRemote")
        XCTAssertEqual(request.headers["apns-push-type"], "alert")
        XCTAssertEqual(request.headers["apns-priority"], "10")
        let authorization: String = try XCTUnwrap(request.headers["authorization"])
        XCTAssertTrue(authorization.hasPrefix("bearer "))
        let jwt = String(authorization.dropFirst("bearer ".count))
        XCTAssertEqual(jwt.split(separator: ".").count, 3)
        XCTAssertFalse(jwt.contains("="))
        XCTAssertFalse(jwt.contains("+"))
        XCTAssertFalse(jwt.contains("/"))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let aps = try XCTUnwrap(object["aps"] as? [String: Any])
        let alert = try XCTUnwrap(aps["alert"] as? [String: Any])
        XCTAssertEqual(alert["title"] as? String, "cmux needs attention")
        XCTAssertEqual(alert["body"] as? String, "Open cmux Remote to review this inbox item.")
        XCTAssertEqual(object["workspace_id"] as? String, "w1")
        XCTAssertEqual(object["surface_id"] as? String, "s1")
        XCTAssertEqual(object["notification_id"] as? String, "n1")
        XCTAssertFalse(String(data: request.body, encoding: .utf8)?.contains("SECRET_TOKEN") ?? true)
    }

    func testDisabledConfigDoesNotHitTransport() async throws {
        let transport = RecordingAPNsTransport()
        let client = APNsProviderClient(
            config: { RelayConfig.defaults.apns },
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let result = try await client.send(samplePush())

        XCTAssertEqual(result, .disabled)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testPayloadTooLargeFailsBeforeTransport() throws {
        let keyURL = try writeTestPrivateKey()
        let config = RelayConfig.APNs(
            keyPath: keyURL.path,
            keyId: "KEY1234567",
            teamId: "TEAM123456",
            topic: "com.genie.CmuxRemote",
            env: "prod"
        )
        let client = APNsProviderClient(
            config: { config },
            transport: RecordingAPNsTransport(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let push = APNsPushAlert(
            deviceToken: "abcdef1234",
            environment: "prod",
            notification: NotificationRecord(
                id: "n1",
                workspaceId: String(repeating: "w", count: 5000),
                surfaceId: nil,
                title: "title",
                subtitle: nil,
                body: "body",
                ts: 42,
                threadId: "workspace-w1"
            )
        )

        XCTAssertThrowsError(try client.prepareRequest(push)) { error in
            XCTAssertEqual(error as? APNsProviderError, .payloadTooLarge)
        }
    }

    func testInvalidTokenResponsesMapToInvalidTokenOutcome() async throws {
        let keyURL = try writeTestPrivateKey()
        let config = RelayConfig.APNs(
            keyPath: keyURL.path,
            keyId: "KEY1234567",
            teamId: "TEAM123456",
            topic: "com.genie.CmuxRemote",
            env: "prod"
        )
        let transport = RecordingAPNsTransport(response: APNsHTTPResponse(
            status: 410,
            headers: ["apns-id": "apns-1"],
            body: Data(#"{"reason":"Unregistered"}"#.utf8)
        ))
        let client = APNsProviderClient(
            config: { config },
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let result = try await client.send(samplePush(environment: "prod"))

        XCTAssertEqual(result, .invalidToken(reason: "Unregistered", apnsId: "apns-1"))
    }

    func testProviderTokenIsCachedAndInvalidatedAfterAuthFailure() async throws {
        let keyURL = try writeTestPrivateKey()
        let config = RelayConfig.APNs(
            keyPath: keyURL.path,
            keyId: "KEY1234567",
            teamId: "TEAM123456",
            topic: "com.genie.CmuxRemote",
            env: "prod"
        )
        let transport = RecordingAPNsTransport(response: APNsHTTPResponse(
            status: 403,
            headers: [:],
            body: Data(#"{"reason":"ExpiredProviderToken"}"#.utf8)
        ))
        let client = APNsProviderClient(
            config: { config },
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let push = samplePush(environment: "prod")

        let first = try XCTUnwrap(client.prepareRequest(push).headers["authorization"])
        let cached = try XCTUnwrap(client.prepareRequest(push).headers["authorization"])
        XCTAssertEqual(first, cached)

        _ = try await client.send(push)

        let afterFailure = try XCTUnwrap(client.prepareRequest(push).headers["authorization"])
        XCTAssertNotEqual(first, afterFailure)
    }

    private func samplePush(environment: String = "sandbox") -> APNsPushAlert {
        APNsPushAlert(
            deviceToken: "abcdef1234",
            environment: environment,
            notification: NotificationRecord(
                id: "n1",
                workspaceId: "w1",
                surfaceId: nil,
                title: "cmux 알림",
                subtitle: nil,
                body: "body",
                ts: 42,
                threadId: "workspace-w1"
            )
        )
    }

    private func writeTestPrivateKey() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("APNsProviderTests-\(UUID().uuidString).p8")
        try testPrivateKeyPEM.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private actor RecordingAPNsTransport: APNsTransport {
    private(set) var requests: [APNsPreparedRequest] = []
    let response: APNsHTTPResponse

    init(response: APNsHTTPResponse = APNsHTTPResponse(status: 200, headers: ["apns-id": "ok"], body: Data())) {
        self.response = response
    }

    func send(_ request: APNsPreparedRequest) async throws -> APNsHTTPResponse {
        requests.append(request)
        return response
    }

    func recordedRequests() -> [APNsPreparedRequest] {
        requests
    }
}

private let testPrivateKeyPEM = """
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIJ9ZRiH6Zi7NBo0e5CnQROhILgAXG+06Gm6YV7S9XD4foAoGCCqGSM49
AwEHoUQDQgAEQh7ms3HNZzwMvqDvH1zlmPYAf77VDqrZ61SopXxHPRkD+FLk5JbH
/gXxUV3DzdU+Sy1ugcsR17n7g17UUQaI1w==
-----END EC PRIVATE KEY-----
"""
