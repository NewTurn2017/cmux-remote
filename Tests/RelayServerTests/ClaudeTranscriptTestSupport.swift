import Darwin
import Foundation
import SharedKit
@testable import RelayServer

/// Scripted cmux `vault.sessions`. The call can be held on a gate to test the relay deadline.
actor FakeVaultCMUX {
    private(set) var calls: [JSONValue] = []
    private let sessions: [JSONValue]
    private let failure: String?
    private let gate: AsyncStream<Void>?

    init(sessions: [JSONValue], failure: String? = nil, gate: AsyncStream<Void>? = nil) {
        self.sessions = sessions
        self.failure = failure
        self.gate = gate
    }

    nonisolated var dispatch: ClaudeTranscriptService.Dispatch {
        { [self] method, params in await self.handle(method, params) }
    }

    private func handle(_ method: String, _ params: JSONValue) async -> TerminalArtifactService.NativeResult {
        guard method == "vault.sessions" else { return .failure(code: "method_not_found") }
        calls.append(params)
        if let gate {
            for await _ in gate { break }
        }
        if let failure { return .failure(code: failure) }
        return .success(.object(["sessions": .array(sessions)]))
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// A temporary directory laid out like `~/.claude/projects` plus a sibling outside the root.
struct TranscriptSandbox {
    let base: URL
    let root: URL
    let project: URL
    let outside: URL

    init() throws {
        guard let temporary = Darwin.realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { free(temporary) }
        base = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
            .appendingPathComponent("cmux-claude-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("projects", isDirectory: true)
        project = root.appendingPathComponent("-Users-example-demo", isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        for directory in [project, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    func write(_ url: URL, _ lines: [Data]) throws -> URL {
        try Data(lines.joined()).write(to: url)
        return url
    }

    func service(_ vault: FakeVaultCMUX, clock: TestClock = TestClock(Date(timeIntervalSince1970: 1_794_240_000)),
                 log: BrowserLogRecorder = BrowserLogRecorder()) -> ClaudeTranscriptService {
        ClaudeTranscriptService(dispatch: vault.dispatch, root: root.path, clock: { clock.now }, log: { log.record($0) })
    }
}

enum TranscriptLine {
    static func json(_ object: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    static func user(_ uuid: String, _ text: String, extra: [String: Any] = [:]) -> Data {
        json(["type": "user", "uuid": uuid, "isSidechain": false, "timestamp": "2026-11-09T00:00:01.000Z",
              "message": ["role": "user", "content": text]].merging(extra) { _, new in new })
    }

    static func assistant(_ uuid: String, messageId: String, _ content: [[String: Any]], extra: [String: Any] = [:]) -> Data {
        json(["type": "assistant", "uuid": uuid, "isSidechain": false, "timestamp": "2026-11-09T00:00:02.000Z",
              "message": ["id": messageId, "role": "assistant", "content": content]].merging(extra) { _, new in new })
    }

    static func vaultSession(_ id: String, file: String?, agent: String = "claude", modified: String = "2026-11-09T10:00:00Z",
                             title: String = "Demo", cwd: String = "/Users/example/demo") -> JSONValue {
        var fields: [String: JSONValue] = [
            "agent": .string(agent), "session_id": .string(id), "title": .string(title), "cwd": .string(cwd),
            "git_branch": .string("main"), "status": .string("idle"), "created": .string("2026-11-09T09:00:00Z"),
            "modified": .string(modified), "resume_command": .string("claude --resume \(id)"),
        ]
        if let file { fields["file"] = .string(file) }
        return .object(fields)
    }
}

enum TranscriptFixture {
    static func url() throws -> URL {
        guard let url = Bundle.module.url(forResource: "claude-transcript-sample", withExtension: "jsonl", subdirectory: "Fixtures") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return url
    }

    static func data() throws -> Data { try Data(contentsOf: url()) }
}

/// Reads one page of `url` with the relay reader, outside the allowed-root checks.
func readTranscriptPage(
    _ url: URL,
    before: Int64? = nil,
    maxEntries: Int = ClaudeTranscriptLimits.maxPageEntries,
    budget: Int = ClaudeTranscriptLimits.maxResponseBytes - ClaudeTranscriptLimits.responseEnvelopeReserveBytes
) throws -> (page: ClaudeTranscriptReader.Page, size: Int64) {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
    defer { _ = Darwin.close(descriptor) }
    var status = Darwin.stat()
    guard Darwin.fstat(descriptor, &status) == 0 else { throw CocoaError(.fileReadUnknown) }
    let size = Int64(status.st_size)
    let page = try ClaudeTranscriptReader.readPage(
        descriptor: descriptor, end: before ?? size, maxEntries: maxEntries, entryBytesBudget: budget
    )
    return (page, size)
}

/// Follows `before` from the newest page to the file start and returns pages newest first.
func readAllTranscriptPages(_ url: URL, maxEntries: Int) throws -> [ClaudeTranscriptReader.Page] {
    var pages: [ClaudeTranscriptReader.Page] = []
    var before: Int64?
    repeat {
        let page = try readTranscriptPage(url, before: before, maxEntries: maxEntries).page
        if let previous = before, let next = page.before, next >= previous { throw CocoaError(.fileReadUnknown) }
        pages.append(page)
        before = page.before
    } while before != nil && pages.count < 10_000
    return pages
}
