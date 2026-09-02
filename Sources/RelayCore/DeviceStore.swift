import Crypto
import Foundation
import Security

/// Persisted device registration. The bearer itself never reaches disk.
public struct Device: Codable, Equatable, Sendable {
    public var deviceId: String
    public var loginName: String
    public var hostname: String
    public var registeredAt: Int64
    public var tokenHash: String
    public var apnsToken: String?
    public var apnsEnv: String?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case loginName = "login_name"
        case hostname
        case registeredAt = "registered_at"
        case tokenHash = "token_hash"
        case apnsToken = "apns_token"
        case apnsEnv = "apns_env"
    }
}

/// Atomic on-disk device registry. Mutations persist a candidate snapshot
/// before publishing it in memory, so a disk error cannot leave the process
/// accepting credentials that disappear after restart.
public final class DeviceStore: @unchecked Sendable {
    public typealias Persist = @Sendable ([String: Device], URL) throws -> Void

    public let url: URL
    private var devices: [String: Device]
    private let persistSnapshot: Persist
    private let queue = DispatchQueue(label: "DeviceStore")

    public convenience init(url: URL) throws {
        try self.init(url: url) { devices, destination in
            try Self.persistToDisk(devices, destination)
        }
    }

    public init(url: URL, persist: @escaping Persist) throws {
        self.url = url
        persistSnapshot = persist
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            do {
                devices = try JSONDecoder().decode([String: Device].self, from: data)
            } catch {
                throw DeviceStoreError.invalidState(url.path)
            }
        } else {
            devices = [:]
            try persistSnapshot(devices, url)
        }
    }

    public func lookup(deviceId: String) -> Device? {
        queue.sync { devices[deviceId] }
    }

    public func allDevices() -> [Device] {
        queue.sync { Array(devices.values) }
    }

    public func register(
        deviceId: String,
        loginName: String,
        hostname: String,
        apnsToken: String?
    ) throws -> String {
        let token = try randomToken()
        let device = Device(
            deviceId: deviceId,
            loginName: loginName,
            hostname: hostname,
            registeredAt: Int64(Date().timeIntervalSince1970),
            tokenHash: hash(token),
            apnsToken: apnsToken,
            apnsEnv: nil
        )
        try mutate { $0[deviceId] = device }
        return token
    }

    public func validate(deviceId: String, token: String) -> Bool {
        guard let device = lookup(deviceId: deviceId) else { return false }
        return constantTimeEqual(device.tokenHash, hash(token))
    }

    public func revoke(deviceId: String) throws {
        try mutate { $0.removeValue(forKey: deviceId) }
    }

    public func setAPNsToken(deviceId: String, token: String, env: String) throws {
        try mutate { candidate in
            guard var device = candidate[deviceId] else {
                throw RelayError.unknownDevice(deviceId)
            }
            device.apnsToken = token
            device.apnsEnv = env
            candidate[deviceId] = device
        }
    }

    public func clearAPNsToken(deviceId: String) throws {
        try mutate { candidate in
            guard var device = candidate[deviceId] else { return }
            device.apnsToken = nil
            device.apnsEnv = nil
            candidate[deviceId] = device
        }
    }

    private func mutate(_ body: (inout [String: Device]) throws -> Void) throws {
        try queue.sync {
            var candidate = devices
            try body(&candidate)
            try persistSnapshot(candidate, url)
            devices = candidate
        }
    }

    public static func persistToDisk(
        _ devices: [String: Device],
        _ url: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(devices).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBufferPointer {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw DeviceStoreError.secureRandom(status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func hash(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(a.utf8, b.utf8) { difference |= left ^ right }
        return difference == 0
    }
}

public enum DeviceStoreError: Error, Equatable {
    case invalidState(String)
    case secureRandom(OSStatus)
}

public enum RelayError: Error, Equatable {
    case unknownDevice(String)
    case unauthorized(String)
    case rateLimited
    case socketUnavailable
    case bootIdMismatch
}
