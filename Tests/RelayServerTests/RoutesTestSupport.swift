import Foundation
@testable import RelayCore

extension DeviceStore {
    /// Test helper — backs a DeviceStore with a fresh per-test temp file so
    /// tests don't share on-disk state. The file path is unique by UUID and
    /// not cleaned up; macOS reaps `temporaryDirectory` on its own cadence
    /// and these are <1KB.
    public static func empty() throws -> DeviceStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceStore-\(UUID()).json")
        return try DeviceStore(url: path)
    }
}

extension RelayConfig {
    /// Test helper — minimal valid config. Concrete values matter only for
    /// the Routes path that touches them: `allowLogin` (register gate),
    /// `snippets` + `defaultFps` (state body).
    public static var testValue: RelayConfig {
        RelayConfig(
            listen: "0.0.0.0:4399",
            allowLogin: ["a@b"],
            apns: .init(keyPath: "/dev/null", keyId: "K",
                        teamId: "T", topic: "x", env: "sandbox"),
            snippets: [],
            defaultFps: 15,
            idleFps: 5
        )
    }
}
