import Crypto
import Foundation
import NIOHTTP1
import RelayCore

struct BearerSourceAuthorizer: Sendable {
    private let deviceStore: DeviceStore
    private let peerResolver: RegistrationPeerResolver

    init(deviceStore: DeviceStore, peerResolver: RegistrationPeerResolver) {
        self.deviceStore = deviceStore
        self.peerResolver = peerResolver
    }

    func authorize(
        headers: HTTPHeaders,
        remoteAddress: String
    ) async -> String? {
        guard let token = Self.bearerToken(from: headers),
              let device = deviceStore.device(matching: token) else {
            return nil
        }
        switch await peerResolver.resolve(remoteAddress: remoteAddress) {
        case .peer(let peer):
            return Self.deviceID(for: peer.nodeKey) == device.deviceId
                ? device.deviceId
                : nil
        case .peerNotFound, .unavailable:
            return nil
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

    static func deviceID(for nodeKey: String) -> String {
        SHA256.hash(data: Data(nodeKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
