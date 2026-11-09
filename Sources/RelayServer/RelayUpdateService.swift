import Darwin
import Foundation
import SharedKit

/// Answers `relay.info` and `relay.update.start` from the updater's files and publishes this relay's
/// runtime state for the updater's restart decision and health check.
///
/// The relay never fetches, builds, or installs anything: the separate launchd job
/// `com.genie.cmuxremote.updater` does, so restarting the relay cannot kill an update in progress.
actor RelayUpdateService {
    enum Error: Swift.Error, Equatable {
        /// Auto-update is turned off in `update/config.json`.
        case disabled
        /// No install record, or the updater job could not be started.
        case unavailable
    }

    /// A pending request older than this is treated as lost, so the phone stops showing `checking`.
    static let requestLifetimeMs: Int64 = 15 * 60 * 1000

    private let paths: RelayUpdatePaths?
    private let version: String
    private let pid: Int32
    private let now: @Sendable () -> Int64
    private let isProcessAlive: @Sendable (Int32) -> Bool
    private let kickstartUpdater: @Sendable () async -> Bool
    private let log: @Sendable (String) -> Void
    private var started = false
    private var startedAtMs: Int64 = 0
    private var activeSessions = 0
    private var zeroSinceMs: Int64?

    init(
        paths: RelayUpdatePaths?,
        version: String = CmuxRemoteVersion.marketing,
        pid: Int32 = getpid(),
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        isProcessAlive: @escaping @Sendable (Int32) -> Bool = { pid in kill(pid, 0) == 0 || errno == EPERM },
        kickstartUpdater: @escaping @Sendable () async -> Bool,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.paths = paths
        self.version = version
        self.pid = pid
        self.now = now
        self.isProcessAlive = isProcessAlive
        self.kickstartUpdater = kickstartUpdater
        self.log = log
    }

    /// A relay that cannot update itself, such as a development run or a test machine.
    static func unavailable() -> RelayUpdateService {
        RelayUpdateService(paths: nil, kickstartUpdater: { false })
    }

    /// The installed relay's service, configured from the launchd environment.
    static func fromEnvironment(
        _ environment: [String: String],
        log: @escaping @Sendable (String) -> Void
    ) -> RelayUpdateService {
        let launchctl = RelayLaunchctlRunner.fromEnvironment(environment)
        return RelayUpdateService(
            paths: RelayUpdatePaths.fromEnvironment(environment),
            kickstartUpdater: { await launchctl.kickstart(label: RelayUpdatePaths.updaterLabel) },
            log: log
        )
    }

    /// `relay.info.v1` always; `relay.update.v1` only when the install record exists.
    func capabilities() -> [String] {
        readConfig() == nil ? [HostCapabilities.relayInfoV1] : [HostCapabilities.relayInfoV1, HostCapabilities.relayUpdateV1]
    }

    func info() -> RelayInfoResult {
        RelayInfoResult(version: version, update: status())
    }

    /// Asks the updater to check, build, and apply now, without waiting for any of it.
    ///
    /// Idempotent: while the updater works it returns the current status, and a staged update is
    /// applied right away because the request bypasses the no-phone rule.
    func start() async throws -> RelayUpdateStatus {
        guard let paths, let config = readConfig() else { throw Error.unavailable }
        guard config.autoUpdate else { throw Error.disabled }
        do {
            try write(
                RelayUpdateRequestFile(
                    schemaVersion: RelayUpdateRequestFile.currentSchemaVersion,
                    source: "user",
                    requestedAtMs: now()
                ),
                to: paths.requestFile
            )
        } catch {
            log("relay update request could not be written: \(error)")
            throw Error.unavailable
        }
        if updaterIsWorking() {
            return status()
        }
        if await kickstartUpdater() || updaterIsWorking() {
            log("relay update requested")
            return status()
        }
        try? FileManager.default.removeItem(at: paths.requestFile)
        throw Error.unavailable
    }

    /// Records that this relay is listening, which the updater's health check waits for.
    func recordStartup() {
        started = true
        startedAtMs = now()
        zeroSinceMs = activeSessions == 0 ? startedAtMs : nil
        writeRuntime()
    }

    func sessionCountChanged(_ count: Int) {
        guard count != activeSessions else { return }
        if count == 0 {
            zeroSinceMs = now()
        } else if activeSessions == 0 {
            zeroSinceMs = nil
        }
        activeSessions = count
        writeRuntime()
    }

    private func status() -> RelayUpdateStatus {
        guard paths != nil, let config = readConfig() else {
            return RelayUpdateStatus(autoUpdateEnabled: false, state: .unavailable)
        }
        let file = readState()
        let adhoc = file?.signing == "adhoc"
        guard config.autoUpdate else {
            return RelayUpdateStatus(
                autoUpdateEnabled: false,
                state: .disabled,
                latestVersion: file?.latestVersion,
                lastCheckedAt: file?.lastCheckedAtMs,
                adhocSigning: adhoc
            )
        }
        var state = file.map { RelayUpdateState(rawValue: $0.state) } ?? .idle
        var code = file?.lastErrorCode.map(RelayUpdateFailureCode.init(rawValue:))
        if state == .disabled {
            state = .idle
        }
        if Self.updaterOwnsProgress(state), !isWorking(file) {
            state = .failed
            code = .interrupted
        }
        if hasPendingRequest(), state == .idle || state == .failed {
            state = .checking
        }
        return RelayUpdateStatus(
            autoUpdateEnabled: true,
            state: state,
            latestVersion: file?.latestVersion,
            lastCheckedAt: file?.lastCheckedAtMs,
            lastErrorCode: state == .failed ? code : nil,
            restartPending: state == .staged || state == .applying,
            adhocSigning: adhoc
        )
    }

    private static func updaterOwnsProgress(_ state: RelayUpdateState) -> Bool {
        state == .checking || state == .downloading || state == .building || state == .applying
    }

    private func updaterIsWorking() -> Bool {
        isWorking(readState())
    }

    private func isWorking(_ file: RelayUpdateStateFile?) -> Bool {
        guard let file, Self.updaterOwnsProgress(RelayUpdateState(rawValue: file.state)),
              let pid = file.pid else { return false }
        return isProcessAlive(pid)
    }

    private func hasPendingRequest() -> Bool {
        guard let paths, let request: RelayUpdateRequestFile = read(paths.requestFile) else { return false }
        return now() - request.requestedAtMs < Self.requestLifetimeMs
    }

    private func writeRuntime() {
        guard started, let paths else { return }
        let runtime = RelayRuntimeFile(
            schemaVersion: RelayRuntimeFile.currentSchemaVersion,
            pid: pid,
            version: version,
            startedAtMs: startedAtMs,
            activeSessions: activeSessions,
            zeroSinceMs: zeroSinceMs
        )
        do {
            try write(runtime, to: paths.runtimeFile)
        } catch {
            log("relay runtime file could not be written: \(error)")
        }
    }

    private func readConfig() -> RelayUpdateConfigFile? {
        paths.flatMap { read($0.configFile) }
    }

    private func readState() -> RelayUpdateStateFile? {
        paths.flatMap { read($0.stateFile) }
    }

    private func read<Value: Decodable>(_ url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? SharedKitJSON.snakeCaseDecoder.decode(Value.self, from: data)
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
