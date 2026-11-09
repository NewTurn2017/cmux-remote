import Darwin
import Foundation

/// Starts the updater job through launchd, so the updater never runs as a child of the relay.
struct RelayLaunchctlRunner: Sendable {
    let executablePath: String

    /// `CMUX_RELAY_LAUNCHCTL` replaces `/bin/launchctl` in tests.
    static func fromEnvironment(_ environment: [String: String]) -> RelayLaunchctlRunner {
        let override = environment["CMUX_RELAY_LAUNCHCTL"].flatMap { $0.isEmpty ? nil : $0 }
        return RelayLaunchctlRunner(executablePath: override ?? "/bin/launchctl")
    }

    /// Runs `launchctl kickstart gui/<uid>/<label>` without `-k`, so an updater that is already
    /// running keeps going.
    ///
    /// - Returns: Whether launchctl exited with status zero.
    func kickstart(label: String) async -> Bool {
        let path = executablePath
        let service = "gui/\(getuid())/\(label)"
        return await BoundedRelayWork.offCooperativePool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["kickstart", service]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return false
            }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }
}
