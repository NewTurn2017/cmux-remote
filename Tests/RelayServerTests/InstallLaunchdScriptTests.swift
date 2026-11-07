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

    /// An empty relay home so the developer's real `~/.cmuxremote` never leaks into a test.
    private func isolatedHome() throws -> [String: String] {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-launchd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return ["CMUX_REMOTE_HOME": home.path, "CMUX_RELAY_CODESIGN_IDENTITY": ""]
    }

    private func runInstaller(
        _ arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repositoryRoot.appendingPathComponent("scripts/install-launchd.sh")
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
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
