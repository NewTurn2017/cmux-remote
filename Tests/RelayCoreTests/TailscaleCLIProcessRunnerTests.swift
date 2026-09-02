import Foundation
import XCTest
@testable import RelayCore

final class TailscaleCLIProcessRunnerTests: XCTestCase {
    func testCollectsConcurrentStdoutAndStderr() throws {
        let script = try executableScript("""
        python3 - <<'PY'
        import sys
        sys.stdout.write('o' * 100000)
        sys.stderr.write('e' * 100000)
        PY
        """)

        let output = try TailscaleCLIProcessRunner.run(
            executableURL: script,
            arguments: [],
            environment: ProcessInfo.processInfo.environment,
            timeout: 2
        )

        XCTAssertEqual(output.terminationStatus, 0)
        XCTAssertEqual(output.stdout.count, 100_000)
        XCTAssertEqual(output.stderr.count, 100_000)
    }

    func testTerminatesProcessAtDeadline() throws {
        let script = try executableScript("sleep 10")
        let started = Date()

        XCTAssertThrowsError(try TailscaleCLIProcessRunner.run(
            executableURL: script,
            arguments: [],
            environment: ProcessInfo.processInfo.environment,
            timeout: 0.05
        )) { error in
            XCTAssertEqual(error as? TailscaleCLIProcessError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    private func executableScript(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscale-runner-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }
}
