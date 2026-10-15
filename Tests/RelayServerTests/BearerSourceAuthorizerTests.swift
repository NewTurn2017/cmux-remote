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

        let decision = await authorizer.authorize(
            headers: headers,
            remoteAddress: "100.64.0.5"
        )

        XCTAssertEqual(
            decision,
            .authorized(deviceID: BearerSourceAuthorizer.deviceID(for: peer.nodeKey))
        )
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

        let decision = await authorizer.authorize(
            headers: headers,
            remoteAddress: "100.64.0.6"
        )
        XCTAssertEqual(decision, .rejected)
    }

    func testAuthorizationFailsClosedWhenWhoisIsUnavailable() async throws {
        let store = try DeviceStore.empty()
        let deviceID = BearerSourceAuthorizer.deviceID(for: "nodekey:owner")
        let token = try store.register(
            deviceId: deviceID,
            loginName: "owner@example.com", hostname: "Owner", apnsToken: nil
        )
        let auth = ControllableAuthService(
            peer: .init(
                loginName: "owner@example.com", hostname: "Owner",
                os: "iOS", nodeKey: "nodekey:owner"
            )
        )
        auth.setPeer(.failure(TailnetIdentityError.serviceUnavailable))
        let resolver = RegistrationPeerResolver(auth: auth)
        let authorizer = BearerSourceAuthorizer(
            deviceStore: store,
            peerResolver: resolver
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token)")

        let decision = await authorizer.authorize(
            headers: headers,
            remoteAddress: "100.64.0.7"
        )
        XCTAssertEqual(decision, .identityUnavailable)
    }

    func testDevLocalhostBearerIsAuthorizedFromLoopbackOnlyWhenEnabled() async throws {
        let store = try DeviceStore.empty()
        let deviceID = BearerSourceAuthorizer.deviceID(
            for: BearerSourceAuthorizer.devLocalhostNodeKey(login: "owner@example.com")
        )
        let token = try store.register(
            deviceId: deviceID,
            loginName: "owner@example.com", hostname: "localhost-dev", apnsToken: nil
        )
        let resolver = RegistrationPeerResolver(auth: MockAuthService(peers: [:]))
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token)")

        let enabled = BearerSourceAuthorizer(
            deviceStore: store, peerResolver: resolver, allowLocalhost: true
        )
        let fromLoopback = await enabled.authorize(headers: headers, remoteAddress: "127.0.0.1")
        XCTAssertEqual(fromLoopback, .authorized(deviceID: deviceID))
        let fromTailnet = await enabled.authorize(headers: headers, remoteAddress: "100.64.0.8")
        XCTAssertEqual(fromTailnet, .rejected)

        let disabled = BearerSourceAuthorizer(deviceStore: store, peerResolver: resolver)
        let withoutBypass = await disabled.authorize(headers: headers, remoteAddress: "127.0.0.1")
        XCTAssertEqual(withoutBypass, .rejected)
    }

    func testLoopbackBypassDoesNotAcceptRealNodeBearer() async throws {
        let store = try DeviceStore.empty()
        let token = try store.register(
            deviceId: BearerSourceAuthorizer.deviceID(for: "nodekey:phone"),
            loginName: "owner@example.com", hostname: "iPhone", apnsToken: nil
        )
        let authorizer = BearerSourceAuthorizer(
            deviceStore: store,
            peerResolver: RegistrationPeerResolver(auth: MockAuthService(peers: [:])),
            allowLocalhost: true
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token)")

        let decision = await authorizer.authorize(headers: headers, remoteAddress: "127.0.0.1")
        XCTAssertEqual(decision, .rejected)
    }

    func testStableIDKeepsBearerValidAcrossNodeKeyRotation() async throws {
        let store = try DeviceStore.empty()
        let deviceID = BearerSourceAuthorizer.deviceID(for: "nodekey:old")
        let token = try store.register(
            deviceId: deviceID,
            loginName: "owner@example.com", hostname: "iPhone", apnsToken: nil
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token)")

        // First request on the original key backfills the stable ID.
        let original = BearerSourceAuthorizer(
            deviceStore: store,
            peerResolver: RegistrationPeerResolver(auth: MockAuthService(peers: [
                "100.64.0.5": PeerIdentity(loginName: "owner@example.com", hostname: "iPhone",
                                           os: "iOS", nodeKey: "nodekey:old", stableID: "nStable1"),
            ]))
        )
        let first = await original.authorize(headers: headers, remoteAddress: "100.64.0.5")
        XCTAssertEqual(first, .authorized(deviceID: deviceID))
        XCTAssertEqual(store.lookup(deviceId: deviceID)?.stableId, "nStable1")

        let rotated = BearerSourceAuthorizer(
            deviceStore: store,
            peerResolver: RegistrationPeerResolver(auth: MockAuthService(peers: [
                "100.64.0.5": PeerIdentity(loginName: "owner@example.com", hostname: "iPhone",
                                           os: "iOS", nodeKey: "nodekey:new", stableID: "nStable1"),
                "100.64.0.6": PeerIdentity(loginName: "owner@example.com", hostname: "Other",
                                           os: "iOS", nodeKey: "nodekey:other", stableID: "nStable2"),
                "100.64.0.7": PeerIdentity(loginName: "owner@example.com", hostname: "NoID",
                                           os: "iOS", nodeKey: "nodekey:noid"),
            ]))
        )
        let afterRotation = await rotated.authorize(headers: headers, remoteAddress: "100.64.0.5")
        XCTAssertEqual(afterRotation, .authorized(deviceID: deviceID))
        let otherNode = await rotated.authorize(headers: headers, remoteAddress: "100.64.0.6")
        XCTAssertEqual(otherNode, .rejected)
        let missingID = await rotated.authorize(headers: headers, remoteAddress: "100.64.0.7")
        XCTAssertEqual(missingID, .rejected)
    }
}
