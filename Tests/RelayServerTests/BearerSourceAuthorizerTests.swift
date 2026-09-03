import NIOHTTP1
import XCTest
@testable import RelayCore
@testable import RelayServer

final class BearerSourceAuthorizerTests: XCTestCase {
    func testAuthorizationBindsBearerToLiveNodeKey() async throws {
        let store = try DeviceStore.empty()
        let peer = PeerIdentity(
            loginName: "owner@example.com", hostname: "iPhone",
            os: "iOS", nodeKey: "nodekey:phone"
        )
        let token = try store.register(
            deviceId: BearerSourceAuthorizer.deviceID(for: peer.nodeKey),
            loginName: peer.loginName,
            hostname: peer.hostname,
            apnsToken: nil
        )
        let resolver = RegistrationPeerResolver(
            auth: MockAuthService(peers: ["100.64.0.5": peer])
        )
        let authorizer = BearerSourceAuthorizer(
            deviceStore: store,
            peerResolver: resolver
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token)")

        let deviceID = await authorizer.authorize(
            headers: headers,
            remoteAddress: "100.64.0.5"
        )

        XCTAssertEqual(deviceID, BearerSourceAuthorizer.deviceID(for: peer.nodeKey))
    }

    func testAuthorizationRejectsBearerFromAnotherLiveNode() async throws {
        let store = try DeviceStore.empty()
        let token = try store.register(
            deviceId: BearerSourceAuthorizer.deviceID(for: "nodekey:owner"),
            loginName: "owner@example.com",
            hostname: "Owner iPhone",
            apnsToken: nil
        )
        let attacker = PeerIdentity(
            loginName: "owner@example.com", hostname: "Other device",
            os: "iOS", nodeKey: "nodekey:other"
        )
        let resolver = RegistrationPeerResolver(
            auth: MockAuthService(peers: ["100.64.0.6": attacker])
        )
        let authorizer = BearerSourceAuthorizer(
            deviceStore: store,
            peerResolver: resolver
        )
        var headers = HTTPHeaders()
        headers.add(name: "Sec-WebSocket-Protocol", value: "cmuxremote.v1, bearer.\(token)")

        let deviceID = await authorizer.authorize(
            headers: headers,
            remoteAddress: "100.64.0.6"
        )
        XCTAssertNil(deviceID)
    }

    func testAuthorizationFailsClosedWhenWhoisIsUnavailable() async throws {
        let store = try DeviceStore.empty()
        let token = try store.register(
            deviceId: BearerSourceAuthorizer.deviceID(for: "nodekey:owner"),
            loginName: "owner@example.com", hostname: "Owner", apnsToken: nil
        )
        let resolver = RegistrationPeerResolver(auth: MockAuthService(peers: [:]))
        let authorizer = BearerSourceAuthorizer(
            deviceStore: store,
            peerResolver: resolver
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token)")

        let deviceID = await authorizer.authorize(
            headers: headers,
            remoteAddress: "100.64.0.7"
        )
        XCTAssertNil(deviceID)
    }
}
