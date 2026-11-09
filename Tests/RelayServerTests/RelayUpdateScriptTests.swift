import Foundation
import Testing

/// Runs the offline updater/installer harness so `swift test` covers the shell side of
/// auto-update. The harness works in its own new temporary directory with local bare
/// repositories as the origin and stubbed launchctl, codesign, and build commands.
@Suite(.serialized)
struct RelayUpdateScriptTests {
    @Test
    func offlineUpdaterHarnessPasses() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repositoryRoot.appendingPathComponent("scripts/tests/relay-update-test.sh")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.standardOutput = output
        process.standardError = output
        // Relay settings from the developer's shell must not steer the harness.
        process.environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("CMUX_") && key != "KEEP_WORK"
        }

        try process.run()
        // Drain the pipe before waiting so a long transcript cannot block the harness.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let transcript = String(decoding: data, as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(transcript)")
        #expect(transcript.contains("relay-update-test: PASS"), "\(transcript)")
    }
}
