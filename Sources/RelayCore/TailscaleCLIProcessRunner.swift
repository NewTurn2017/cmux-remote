import Darwin
import Foundation

struct TailscaleCLIProcessOutput: Sendable {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32
}

enum TailscaleCLIProcessError: Error, Equatable {
    case timedOut
}

/// Runs the bundled Tailscale CLI without allowing a stuck GUI or XPC bridge
/// to wedge registration. Both pipes drain concurrently, which also avoids the
/// `status --json` stdout pipe filling before the process can exit.
struct TailscaleCLIProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval = 5
    ) throws -> TailscaleCLIProcessOutput {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let output = LockedProcessOutput()
        let drains = DispatchGroup()
        let terminated = DispatchSemaphore(value: 0)

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in terminated.signal() }

        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            output.setStdout(stdout.fileHandleForReading.readDataToEndOfFile())
            drains.leave()
        }
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            output.setStderr(stderr.fileHandleForReading.readDataToEndOfFile())
            drains.leave()
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForWriting.closeFile()
            stderr.fileHandleForWriting.closeFile()
            drains.wait()
            throw error
        }
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()

        let deadline = DispatchTime.now() + timeout
        guard terminated.wait(timeout: deadline) == .success else {
            process.terminate()
            if terminated.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
            drains.wait()
            throw TailscaleCLIProcessError.timedOut
        }

        drains.wait()
        let snapshot = output.snapshot()
        return TailscaleCLIProcessOutput(
            stdout: snapshot.stdout,
            stderr: snapshot.stderr,
            terminationStatus: process.terminationStatus
        )
    }
}

private final class LockedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func setStdout(_ data: Data) {
        lock.lock()
        stdout = data
        lock.unlock()
    }

    func setStderr(_ data: Data) {
        lock.lock()
        stderr = data
        lock.unlock()
    }

    func snapshot() -> (stdout: Data, stderr: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr)
    }
}
