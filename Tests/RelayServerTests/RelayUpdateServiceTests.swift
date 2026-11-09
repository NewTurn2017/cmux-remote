import XCTest
import SharedKit
@testable import RelayServer

final class RelayUpdateServiceTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-update-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    func testWithoutRelayHomeReportsUnavailableAndAdvertisesInfoOnly() async throws {
        let kickstart = KickstartRecorder(result: true)
        let service = makeService(development: true, kickstart: kickstart)

        let capabilities = await service.capabilities()
        XCTAssertEqual(capabilities, ["relay.info.v1"])
        let info = await service.info()
        XCTAssertEqual(info, RelayInfoResult(version: "2.0.0", update: RelayUpdateStatus(autoUpdateEnabled: false, state: .unavailable)))
        await assertStart(service, throws: .unavailable)
        XCTAssertEqual(kickstart.count, 0)
    }

    func testMissingInstallRecordIsUnavailable() async throws {
        let kickstart = KickstartRecorder(result: true)
        let service = makeService(kickstart: kickstart)

        let capabilities = await service.capabilities()
        XCTAssertEqual(capabilities, ["relay.info.v1"])
        let info = await service.info()
        XCTAssertEqual(info.update, RelayUpdateStatus(autoUpdateEnabled: false, state: .unavailable))
        await assertStart(service, throws: .unavailable)
        XCTAssertEqual(kickstart.count, 0)
    }

    func testDisabledInstallAdvertisesUpdateButRefusesToStart() async throws {
        try writeConfig(autoUpdate: false)
        try writeUpdateFile("state.json", #"{"schema_version":1,"state":"disabled","latest_version":"2.0.1","last_checked_at_ms":900}"#)
        let kickstart = KickstartRecorder(result: true)
        let service = makeService(kickstart: kickstart)

        let capabilities = await service.capabilities()
        XCTAssertEqual(capabilities, ["relay.info.v1", "relay.update.v1"])
        let info = await service.info()
        XCTAssertEqual(info.update, RelayUpdateStatus(autoUpdateEnabled: false, state: .disabled, latestVersion: "2.0.1", lastCheckedAt: 900))
        await assertStart(service, throws: .disabled)
        XCTAssertEqual(kickstart.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.requestFile.path))
    }

    func testEnabledInstallWithoutStateIsIdle() async throws {
        try writeConfig(autoUpdate: true)
        let info = await makeService().info()
        XCTAssertEqual(info.update, RelayUpdateStatus(autoUpdateEnabled: true, state: .idle))
    }

    func testStateFileMapsToStatus() async throws {
        try writeConfig(autoUpdate: true)
        let service = makeService(alive: [77])

        try writeUpdateFile("state.json", #"{"schema_version":1,"state":"staged","latest_version":"2.0.1","last_checked_at_ms":900,"signing":"adhoc","next_check_at_ms":5}"#)
        var info = await service.info()
        XCTAssertEqual(info.update, RelayUpdateStatus(
            autoUpdateEnabled: true, state: .staged, latestVersion: "2.0.1", lastCheckedAt: 900,
            restartPending: true, adhocSigning: true
        ))

        try writeUpdateFile("state.json", #"{"schema_version":1,"state":"applying","pid":77,"latest_version":"2.0.1","signing":"identity"}"#)
        info = await service.info()
        XCTAssertEqual(info.update, RelayUpdateStatus(autoUpdateEnabled: true, state: .applying, latestVersion: "2.0.1", restartPending: true))

        try writeUpdateFile("state.json", #"{"schema_version":1,"state":"failed","last_error_code":"build_failed","latest_version":"2.0.1"}"#)
        info = await service.info()
        XCTAssertEqual(info.update, RelayUpdateStatus(autoUpdateEnabled: true, state: .failed, latestVersion: "2.0.1", lastErrorCode: .buildFailed))

        try writeUpdateFile("state.json", #"{"schema_version":1,"state":"verifying","last_error_code":"quota_exceeded"}"#)
        info = await service.info()
        XCTAssertEqual(info.update, RelayUpdateStatus(autoUpdateEnabled: true, state: .unknown("verifying")))
    }

    func testProgressFromADeadUpdaterIsInterrupted() async throws {
        try writeConfig(autoUpdate: true)
        try writeUpdateFile("state.json", #"{"schema_version":1,"state":"building","pid":77,"latest_version":"2.0.1"}"#)
        let info = await makeService(alive: []).info()
        XCTAssertEqual(info.update, RelayUpdateStatus(autoUpdateEnabled: true, state: .failed, latestVersion: "2.0.1", lastErrorCode: .interrupted))
    }

    func testStartWritesRequestAndKickstartsTheUpdater() async throws {
        try writeConfig(autoUpdate: true)
        try writeUpdateFile("state.json", #"{"schema_version":1,"state":"idle","latest_version":"2.0.0","last_checked_at_ms":900}"#)
        let kickstart = KickstartRecorder(result: true)
        let service = makeService(clock: RelayUpdateTestClock(5_000), kickstart: kickstart)

        let started = try await service.start()

        XCTAssertEqual(started, RelayUpdateStatus(autoUpdateEnabled: true, state: .checking, latestVersion: "2.0.0", lastCheckedAt: 900))
        XCTAssertEqual(kickstart.count, 1)
        let request = try SharedKitJSON.snakeCaseDecoder.decode(
            RelayUpdateRequestFile.self,
            from: Data(contentsOf: paths.requestFile)
        )
        XCTAssertEqual(request, RelayUpdateRequestFile(schemaVersion: 1, source: "user", requestedAtMs: 5_000))
        let info = await service.info()
        XCTAssertEqual(info.update?.state, .checking)
    }

    func testStartWhileTheUpdaterWorksIsIdempotent() async throws {
        try writeConfig(autoUpdate: true)
        try writeUpdateFile("state.json", #"{"schema_version":1,"state":"building","pid":77,"latest_version":"2.0.1"}"#)
        let kickstart = KickstartRecorder(result: true)
        let service = makeService(alive: [77], kickstart: kickstart)

        let first = try await service.start()
        let second = try await service.start()

        let building = RelayUpdateStatus(autoUpdateEnabled: true, state: .building, latestVersion: "2.0.1")
        XCTAssertEqual(first, building)
        XCTAssertEqual(second, building)
        XCTAssertEqual(kickstart.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.requestFile.path))
    }

    func testStartWhileStagedAsksTheUpdaterToApplyNow() async throws {
        try writeConfig(autoUpdate: true)
        try writeUpdateFile("state.json", #"{"schema_version":1,"state":"staged","latest_version":"2.0.1"}"#)
        let kickstart = KickstartRecorder(result: true)
        let service = makeService(kickstart: kickstart)

        let started = try await service.start()

        XCTAssertEqual(started, RelayUpdateStatus(autoUpdateEnabled: true, state: .staged, latestVersion: "2.0.1", restartPending: true))
        XCTAssertEqual(kickstart.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.requestFile.path))
    }

    func testStartIsUnavailableWhenTheUpdaterCannotStart() async throws {
        try writeConfig(autoUpdate: true)
        let kickstart = KickstartRecorder(result: false)
        let service = makeService(kickstart: kickstart)

        await assertStart(service, throws: .unavailable)

        XCTAssertEqual(kickstart.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.requestFile.path))
    }

    func testStaleRequestStopsShowingChecking() async throws {
        try writeConfig(autoUpdate: true)
        try writeUpdateFile("request.json", #"{"schema_version":1,"source":"user","requested_at_ms":1000}"#)
        let clock = RelayUpdateTestClock(1_000 + RelayUpdateService.requestLifetimeMs - 1)
        let service = makeService(clock: clock)

        var info = await service.info()
        XCTAssertEqual(info.update?.state, .checking)
        clock.set(1_000 + RelayUpdateService.requestLifetimeMs)
        info = await service.info()
        XCTAssertEqual(info.update?.state, .idle)
    }

    func testRuntimeFileTracksStartupAndPhoneConnections() async throws {
        let clock = RelayUpdateTestClock(500)
        let service = makeService(clock: clock)

        await service.sessionCountChanged(0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.runtimeFile.path), "nothing is written before the relay listens")

        clock.set(1_000)
        await service.recordStartup()
        XCTAssertEqual(try runtimeJSON(), #"{"active_sessions":0,"pid":4242,"schema_version":1,"started_at_ms":1000,"version":"2.0.0","zero_since_ms":1000}"#)

        clock.set(2_000)
        await service.sessionCountChanged(1)
        XCTAssertEqual(try runtimeJSON(), #"{"active_sessions":1,"pid":4242,"schema_version":1,"started_at_ms":1000,"version":"2.0.0"}"#)

        clock.set(2_500)
        await service.sessionCountChanged(2)
        clock.set(3_000)
        await service.sessionCountChanged(0)
        XCTAssertEqual(try runtimeJSON(), #"{"active_sessions":0,"pid":4242,"schema_version":1,"started_at_ms":1000,"version":"2.0.0","zero_since_ms":3000}"#)
    }

    func testDevelopmentRunWritesNoRuntimeFile() async throws {
        let service = makeService(development: true)
        await service.recordStartup()
        await service.sessionCountChanged(1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.updateDirectory.path))
    }

    func testPathsComeFromTheLaunchdEnvironment() {
        XCTAssertNil(RelayUpdatePaths.fromEnvironment([:]))
        XCTAssertNil(RelayUpdatePaths.fromEnvironment(["CMUX_REMOTE_HOME": ""]))
        let paths = RelayUpdatePaths.fromEnvironment(["CMUX_REMOTE_HOME": "/tmp/relay-home"])
        XCTAssertEqual(paths?.runtimeFile.path, "/tmp/relay-home/update/relay-runtime.json")
        XCTAssertEqual(paths?.requestFile.path, "/tmp/relay-home/update/request.json")
        XCTAssertEqual(RelayUpdatePaths.updaterLabel, "com.genie.cmuxremote.updater")
        XCTAssertEqual(RelayLaunchctlRunner.fromEnvironment([:]).executablePath, "/bin/launchctl")
        XCTAssertEqual(RelayLaunchctlRunner.fromEnvironment(["CMUX_RELAY_LAUNCHCTL": "/tmp/stub"]).executablePath, "/tmp/stub")
    }

    private var paths: RelayUpdatePaths { RelayUpdatePaths(home: home) }

    private func makeService(
        development: Bool = false,
        clock: RelayUpdateTestClock = RelayUpdateTestClock(1_000),
        alive: Set<Int32> = [],
        kickstart: KickstartRecorder = KickstartRecorder(result: true)
    ) -> RelayUpdateService {
        RelayUpdateService(
            paths: development ? nil : paths,
            version: "2.0.0",
            pid: 4242,
            now: { clock.now },
            isProcessAlive: { alive.contains($0) },
            kickstartUpdater: { kickstart.record() }
        )
    }

    private func assertStart(
        _ service: RelayUpdateService,
        throws expected: RelayUpdateService.Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let status = try await service.start()
            XCTFail("expected \(expected), got \(status)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RelayUpdateService.Error, expected, file: file, line: line)
        }
    }

    private func writeConfig(autoUpdate: Bool) throws {
        try writeUpdateFile("config.json", #"{"schema_version":1,"auto_update":\#(autoUpdate),"origin":"https://github.com/NewTurn2017/cmux-remote.git","check_interval_seconds":3600,"idle_restart_seconds":120,"installed_version":"2.0.0"}"#)
    }

    private func writeUpdateFile(_ name: String, _ json: String) throws {
        try FileManager.default.createDirectory(at: paths.updateDirectory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: paths.updateDirectory.appendingPathComponent(name))
    }

    private func runtimeJSON() throws -> String {
        String(decoding: try Data(contentsOf: paths.runtimeFile), as: UTF8.self)
    }
}

final class KickstartRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let result: Bool
    private var calls = 0

    init(result: Bool) {
        self.result = result
    }

    var count: Int { lock.withLock { calls } }

    func record() -> Bool {
        lock.withLock { calls += 1 }
        return result
    }
}

final class RelayUpdateTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds: Int64

    init(_ milliseconds: Int64) {
        self.milliseconds = milliseconds
    }

    var now: Int64 { lock.withLock { milliseconds } }

    func set(_ milliseconds: Int64) {
        lock.withLock { self.milliseconds = milliseconds }
    }
}
