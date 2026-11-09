import Foundation
import Testing

@Suite(.serialized)
struct InstallLaunchdScriptTests {
    @Test
    func rejectsEmptyAndOptionLikeSocketPaths() throws {
        let invalidArguments = [
            ["--dry-run", "--socket="],
            ["--dry-run", "--socket", ""],
            ["--dry-run", "--socket", "--help"],
        ]

        for arguments in invalidArguments {
            let result = try runInstaller(arguments)
            #expect(result.status == 2, "arguments \(arguments) returned \(result.status)")
            #expect(result.output.contains("--socket requires a path"))
        }
    }

    @Test
    func acceptsExplicitSocketPath() throws {
        let result = try runInstaller(["--dry-run", "--socket", "/tmp/cmux.sock"])

        #expect(result.status == 0)
        #expect(result.output.contains("socket override: /tmp/cmux.sock"))
    }

    @Test
    func persistsSelfLoginOptOutInLaunchAgent() throws {
        let result = try runInstaller(
            ["--dry-run"],
            environment: ["CMUX_NO_SELF_LOGIN": "1"]
        )

        #expect(result.status == 0)
        #expect(result.output.contains("<key>CMUX_NO_SELF_LOGIN</key>"))
        #expect(result.output.contains("<string>1</string>"))
    }

    @Test
    func rejectsMissingAndOptionLikeSignIdentities() throws {
        for arguments in [["--dry-run", "--sign"], ["--dry-run", "--sign="], ["--dry-run", "--sign", "--help"]] {
            let result = try runInstaller(arguments, environment: try isolatedHome())
            #expect(result.status == 2, "arguments \(arguments) returned \(result.status)")
            #expect(result.output.contains("--sign requires an identity"))
        }
    }

    @Test
    func resolvesSignIdentityFromFlagThenEnvironmentThenRememberedFile() throws {
        var environment = try isolatedHome()
        let home = try #require(environment["CMUX_REMOTE_HOME"])

        let unsigned = try runInstaller(["--dry-run"], environment: environment)
        #expect(unsigned.status == 0)
        #expect(unsigned.output.contains("codesign identity: adhoc"))

        try "Remembered Identity\n".write(
            toFile: home + "/codesign-identity", atomically: true, encoding: .utf8
        )
        let remembered = try runInstaller(["--dry-run"], environment: environment)
        #expect(remembered.output.contains("codesign identity: Remembered Identity (from \(home)/codesign-identity)"))

        environment["CMUX_RELAY_CODESIGN_IDENTITY"] = "Env Identity"
        let fromEnvironment = try runInstaller(["--dry-run"], environment: environment)
        #expect(fromEnvironment.output.contains("codesign identity: Env Identity (from CMUX_RELAY_CODESIGN_IDENTITY)"))

        let fromFlag = try runInstaller(["--dry-run", "--sign", "Flag Identity"], environment: environment)
        #expect(fromFlag.output.contains("codesign identity: Flag Identity (from --sign)"))

        let backToAdhoc = try runInstaller(["--dry-run", "--sign=adhoc"], environment: environment)
        #expect(backToAdhoc.output.contains("codesign identity: adhoc"))
    }

    @Test
    func dryRunShowsTheUpdaterThatAFirstInstallAdds() throws {
        let environment = try isolatedHome()
        let home = try #require(environment["CMUX_REMOTE_HOME"])
        let agents = try #require(environment["CMUX_LAUNCH_AGENTS_DIR"])

        let result = try runInstaller(["--dry-run"], environment: environment)

        #expect(result.status == 0)
        #expect(result.output.contains(
            "auto-update: enabled (origin https://github.com/NewTurn2017/cmux-remote.git, tags vX.Y.Z only"
        ))
        #expect(result.output.contains("updater label: com.genie.cmuxremote.updater"))
        #expect(result.output.contains("would install: "))
        #expect(result.output.contains("-> \(home)/libexec/relay-update.sh"))
        #expect(result.output.contains("would write: \(home)/update/config.json (auto_update=true)"))
        #expect(result.output.contains("updater plist: \(agents)/com.genie.cmuxremote.updater.plist"))
        #expect(result.output.contains("managed clone (first new release): \(home)/src/cmux-remote"))
        #expect(result.output.contains("--- rendered updater plist ---"))
        #expect(result.output.contains("<string>com.genie.cmuxremote.updater</string>"))
        #expect(result.output.contains("<key>CMUX_REMOTE_HOME</key>"))
        #expect(result.output.contains("<string>\(home)</string>"))
    }

    @Test
    func dryRunWithoutAutoUpdateInstallsNoUpdater() throws {
        let environment = try isolatedHome()
        let home = try #require(environment["CMUX_REMOTE_HOME"])

        let result = try runInstaller(["--dry-run", "--no-auto-update"], environment: environment)

        #expect(result.status == 0)
        #expect(result.output.contains("auto-update: disabled (from --no-auto-update"))
        #expect(result.output.contains("would write: \(home)/update/config.json (auto_update=false)"))
        #expect(result.output.contains("not installed: updater job com.genie.cmuxremote.updater"))
        #expect(!result.output.contains("--- rendered updater plist ---"))
        #expect(!result.output.contains("would install: "))
    }

    @Test
    func dryRunFollowsTheRememberedUpdateChoiceAndOrigin() throws {
        let environment = try isolatedHome()
        let home = try #require(environment["CMUX_REMOTE_HOME"])
        try FileManager.default.createDirectory(
            atPath: home + "/update", withIntermediateDirectories: true
        )
        try """
        {"schema_version":1,"auto_update":false,"origin":"https://example.com/fork/cmux-remote.git",\
        "check_interval_seconds":3600,"idle_restart_seconds":120,"installed_version":"2.0.0"}
        """.write(toFile: home + "/update/config.json", atomically: true, encoding: .utf8)

        let remembered = try runInstaller(["--dry-run"], environment: environment)
        #expect(remembered.status == 0)
        #expect(remembered.output.contains("auto-update: disabled (from \(home)/update/config.json"))

        let turnedBackOn = try runInstaller(["--dry-run", "--auto-update"], environment: environment)
        #expect(turnedBackOn.status == 0)
        #expect(turnedBackOn.output.contains(
            "auto-update: enabled (origin https://example.com/fork/cmux-remote.git, tags vX.Y.Z only"
        ))

        let overridden = try runInstaller(
            ["--dry-run", "--auto-update", "--update-origin", "https://example.com/other/cmux-remote.git"],
            environment: environment
        )
        #expect(overridden.output.contains("auto-update: enabled (origin https://example.com/other/cmux-remote.git"))
    }

    @Test
    func rejectsUpdateOriginsThatAreNotHTTPS() throws {
        let invalidArguments = [
            ["--dry-run", "--update-origin", "http://example.com/cmux-remote.git"],
            ["--dry-run", "--update-origin", "git@github.com:NewTurn2017/cmux-remote.git"],
            ["--dry-run", "--update-origin", "file:///tmp/cmux-remote.git"],
            ["--dry-run", "--update-origin", ""],
            ["--dry-run", "--update-origin="],
            ["--dry-run", "--update-origin"],
        ]

        for arguments in invalidArguments {
            let result = try runInstaller(arguments, environment: try isolatedHome())
            #expect(result.status == 2, "arguments \(arguments) returned \(result.status)")
            #expect(result.output.contains("--update-origin requires an https:// git URL"))
        }
    }

    @Test
    func uninstallDryRunRemovesTheUpdaterAndItsCacheByDefault() throws {
        let environment = try isolatedHome()
        let home = try #require(environment["CMUX_REMOTE_HOME"])
        let agents = try #require(environment["CMUX_LAUNCH_AGENTS_DIR"])

        let result = try runUninstaller(["--dry-run"], environment: environment)

        #expect(result.status == 0)
        #expect(result.output.contains("would run: launchctl bootout gui/\(getuid())/com.genie.cmuxremote.updater"))
        #expect(result.output.contains("would remove: \(agents)/com.genie.cmuxremote.updater.plist"))
        #expect(result.output.contains("would remove: \(home)/libexec/relay-update.sh"))
        #expect(result.output.contains("would remove: \(home)/update"))
        #expect(result.output.contains("would remove: \(home)/src/cmux-remote"))
        #expect(result.output.contains("keeping: relay.json, devices.json, codesign-identity, bin/"))
    }

    @Test
    func uninstallDryRunKeepsTheUpdateCacheWhenAsked() throws {
        let environment = try isolatedHome()
        let home = try #require(environment["CMUX_REMOTE_HOME"])

        let result = try runUninstaller(["--dry-run", "--keep-update-cache"], environment: environment)

        #expect(result.status == 0)
        #expect(result.output.contains("keeping (--keep-update-cache): \(home)/src/cmux-remote"))
        #expect(!result.output.contains("would remove: \(home)/src/cmux-remote"))
        #expect(result.output.contains("would remove: \(home)/update"))
    }

    /// An empty relay home so the developer's real `~/.cmuxremote` never leaks into a test.
    private func isolatedHome() throws -> [String: String] {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-launchd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return [
            "CMUX_REMOTE_HOME": home.path,
            "CMUX_LAUNCH_AGENTS_DIR": home.appendingPathComponent("LaunchAgents").path,
            "CMUX_RELAY_CODESIGN_IDENTITY": "",
            "CMUX_RELAY_UPDATE_ORIGIN": "",
            "CMUX_RELAY_UPDATE_TEST": "",
        ]
    }

    private func runInstaller(
        _ arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        try runScript("scripts/install-launchd.sh", arguments, environment: environment)
    }

    private func runUninstaller(
        _ arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        try runScript("scripts/uninstall-launchd.sh", arguments, environment: environment)
    }

    private func runScript(
        _ relativePath: String,
        _ arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repositoryRoot.appendingPathComponent(relativePath)
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        process.standardOutput = output
        process.standardError = output
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, override in override }
        )

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
