import Crypto
import Foundation
import NIOHTTP1
import RelayCore

struct BearerSourceAuthorizer: Sendable {
    enum Decision: Equatable, Sendable {
        case authorized(deviceID: String)
        case rejected
        case identityUnavailable
    }

    private let deviceStore: DeviceStore
    private let peerResolver: RegistrationPeerResolver
    private let allowLocalhost: Bool

    init(
        deviceStore: DeviceStore,
        peerResolver: RegistrationPeerResolver,
        allowLocalhost: Bool = false
    ) {
        self.deviceStore = deviceStore
        self.peerResolver = peerResolver
        self.allowLocalhost = allowLocalhost
    }

    func authorize(
        headers: HTTPHeaders,
        remoteAddress: String
    ) async -> Decision {
        guard let token = Self.bearerToken(from: headers),
              let device = deviceStore.device(matching: token) else {
            return .rejected
        }
        // Dev bypass mirrors registration: a loopback caller can't be resolved
        // by tailscaled, so it may only use a bearer minted for the synthetic
        // localhost node. Real-node bearers still need a live whois match.
        if allowLocalhost, Routes.isLoopback(remoteAddress),
           device.deviceId == Self.deviceID(for: Self.devLocalhostNodeKey(login: device.loginName)) {
            return .authorized(deviceID: device.deviceId)
        }
        switch await peerResolver.resolve(remoteAddress: remoteAddress) {
        case .peer(let peer):
            guard Self.deviceID(for: peer.nodeKey) == device.deviceId else {
                return .rejected
            }
            return .authorized(deviceID: device.deviceId)
        case .peerNotFound:
            return .rejected
        case .unavailable:
            return .identityUnavailable
        }
    }

    static func bearerToken(from headers: HTTPHeaders) -> String? {
        var candidates: [String] = []
        if let authorization = headers.first(name: "Authorization") {
            let prefix = "Bearer "
            if authorization.lowercased().hasPrefix(prefix.lowercased()) {
                let token = authorization.dropFirst(prefix.count)
                    .trimmingCharacters(in: .whitespaces)
                if !token.isEmpty { candidates.append(token) }
            }
        }
        if let protocols = headers.first(name: "Sec-WebSocket-Protocol") {
            for part in protocols.split(separator: ",") {
                let value = part.trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("bearer.") {
                    let token = value.dropFirst("bearer.".count)
                    if !token.isEmpty { candidates.append(String(token)) }
                }
            }
        }
        return candidates.first
    }

    static func devLocalhostNodeKey(login: String) -> String {
        "cmux-dev-localhost:\(login)"
    }

    static func deviceID(for nodeKey: String) -> String {
        SHA256.hash(data: Data(nodeKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
