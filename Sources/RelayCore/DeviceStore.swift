import Foundation
import Crypto
import Security

/// Persisted device registration. The device's bearer token is never stored
/// in plaintext — only the SHA-256 hex of the 32-byte random token issued at
/// `register()` time. Validation hashes the presented token and compares in
/// constant time.
public struct Device: Codable, Equatable, Sendable {
    public var deviceId: String
    public var loginName: String
    public var hostname: String
    public var registeredAt: Int64
    public var tokenHash: String       // SHA256-hex of the raw bearer
    public var apnsToken: String?
    public var apnsEnv: String?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id", loginName = "login_name", hostname,
             registeredAt = "registered_at", tokenHash = "token_hash",
             apnsToken = "apns_token", apnsEnv = "apns_env"
    }
}

/// Atomic on-disk device registry. Spec section 7.1 / 7.2.
///
/// Lives at `~/.cmuxremote/devices.json` so the relay never rewrites the
/// user's hand-edited `relay.json`. Mutations serialize through a private
/// `DispatchQueue`; reads use `queue.sync`. `@unchecked Sendable` is sound
/// because every access goes through the queue.
public final class DeviceStore: @unchecked Sendable {
    public let url: URL
    private var devices: [String: Device] = [:]
    private let queue = DispatchQueue(label: "DeviceStore")

    public init(url: URL) throws {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Device].self, from: data) {
            self.devices = decoded
        } else {
            try persist()
        }
    }

    public func lookup(deviceId: String) -> Device? {
        queue.sync { devices[deviceId] }
    }

    public func allDevices() -> [Device] {
        queue.sync { Array(devices.values) }
    }

    public func register(deviceId: String, loginName: String,
                         hostname: String, apnsToken: String?) throws -> String
    {
        let raw = randomToken()
        let device = Device(deviceId: deviceId, loginName: loginName,
                            hostname: hostname,
                            registeredAt: Int64(Date().timeIntervalSince1970),
                            tokenHash: hash(raw),
                            apnsToken: apnsToken, apnsEnv: nil)
        try queue.sync {
            devices[deviceId] = device
            try persist()
        }
        return raw
    }

    public func validate(deviceId: String, token: String) -> Bool {
        guard let dev = lookup(deviceId: deviceId) else { return false }
        return constantTimeEqual(dev.tokenHash, hash(token))
    }

    public func revoke(deviceId: String) throws {
        try queue.sync {
            devices.removeValue(forKey: deviceId)
            try persist()
        }
    }

    public func setAPNsToken(deviceId: String, token: String, env: String) throws {
        try queue.sync {
            guard var dev = devices[deviceId] else { throw RelayError.unknownDevice(deviceId) }
            dev.apnsToken = token
            dev.apnsEnv = env
            devices[deviceId] = dev
            try persist()
        }
    }

    public func clearAPNsToken(deviceId: String) throws {
        try queue.sync {
            guard var dev = devices[deviceId] else { return }
            dev.apnsToken = nil; dev.apnsEnv = nil
            devices[deviceId] = dev
            try persist()
        }
    }

    private func persist() throws {
        let tmp = url.appendingPathExtension("tmp")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(devices)
        try data.write(to: tmp, options: .atomic)
        // replaceItemAt is no-op if the destination doesn't exist; on first
        // write fall through to a plain move.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    private func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = bytes.withUnsafeMutableBufferPointer {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func hash(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a.utf8, b.utf8) { diff |= x ^ y }
        return diff == 0
    }
}

public enum RelayError: Error, Equatable {
    case unknownDevice(String)
    case unauthorized(String)
    case rateLimited
    case socketUnavailable
    case bootIdMismatch
}
