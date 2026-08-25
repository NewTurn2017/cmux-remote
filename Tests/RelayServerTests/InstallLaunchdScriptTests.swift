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

    private func runInstaller(_ arguments: [String]) throws -> (status: Int32, output: String) {
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

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
