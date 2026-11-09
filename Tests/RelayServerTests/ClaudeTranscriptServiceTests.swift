import Darwin
import Foundation
import SharedKit
import Testing
@testable import RelayServer

@Suite("ClaudeTranscriptServiceTests")
struct ClaudeTranscriptServiceTests {
    private static let budget = ClaudeTranscriptLimits.maxResponseBytes - ClaudeTranscriptLimits.responseEnvelopeReserveBytes

    private struct Layout {
        let sandbox: TranscriptSandbox
        let sessions: [JSONValue]
        let ok: URL
        let profilePath: String
        let escape: URL
        let fifo: URL
        let directory: URL
        let dotdot: String
        let text: URL
        let deep: URL
    }

    private func layout() throws -> Layout {
        let sandbox = try TranscriptSandbox()
        let lines = [TranscriptLine.user("u1", "hello"), TranscriptLine.assistant("a1", messageId: "m1", [["type": "text", "text": "hi"]])]
        let ok = try sandbox.write(sandbox.project.appendingPathComponent("s-ok.jsonl"), lines)
        try sandbox.write(sandbox.project.appendingPathComponent("s-profile.jsonl"), lines)
        let profiles = sandbox.base.appendingPathComponent("profiles/work", isDirectory: true)
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: profiles.appendingPathComponent("projects"), withDestinationURL: sandbox.root)
        let profilePath = profiles.appendingPathComponent("projects/-Users-example-demo/s-profile.jsonl").path
        let outsideFile = try sandbox.write(sandbox.outside.appendingPathComponent("s-outside.jsonl"), lines)
        let escape = sandbox.project.appendingPathComponent("s-escape.jsonl")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outsideFile)
        let text = try sandbox.write(sandbox.project.appendingPathComponent("s-text.txt"), lines)
        let directory = sandbox.project.appendingPathComponent("s-dir.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fifo = sandbox.project.appendingPathComponent("s-fifo.jsonl")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let deepDirectory = sandbox.root.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: deepDirectory, withIntermediateDirectories: true)
        let deep = try sandbox.write(deepDirectory.appendingPathComponent("s-deep.jsonl"), lines)
        let dotdot = sandbox.project.path + "/../-Users-example-demo/s-ok.jsonl"

        let sessions: [JSONValue] = [
            TranscriptLine.vaultSession("s-ok", file: ok.path, modified: "2026-11-09T10:00:00Z"),
            TranscriptLine.vaultSession("s-profile", file: profilePath, modified: "2026-11-09T11:00:00Z"),
            TranscriptLine.vaultSession("s-nofile", file: nil),
            TranscriptLine.vaultSession("s-outside", file: outsideFile.path),
            TranscriptLine.vaultSession("s-escape", file: escape.path),
            TranscriptLine.vaultSession("s-text", file: text.path),
            TranscriptLine.vaultSession("s-dir", file: directory.path),
            TranscriptLine.vaultSession("s-fifo", file: fifo.path),
            TranscriptLine.vaultSession("s-deep", file: deep.path),
            TranscriptLine.vaultSession("s-dotdot", file: dotdot),
            TranscriptLine.vaultSession("s-codex", file: ok.path, agent: "codex"),
            TranscriptLine.vaultSession("../s-bad", file: ok.path),
        ]
        return Layout(sandbox: sandbox, sessions: sessions, ok: ok, profilePath: profilePath, escape: escape,
                      fifo: fifo, directory: directory, dotdot: dotdot, text: text, deep: deep)
    }

    @Test func sessionsDropMissingFileOutsideRootSymlinkEscapeAndNonJsonl() async throws {
        let layout = try layout()
        defer { layout.sandbox.remove() }
        let vault = FakeVaultCMUX(sessions: layout.sessions)
        let log = BrowserLogRecorder()
        let service = layout.sandbox.service(vault, log: log)

        let result = try await service.sessions(limit: 50)

        #expect(result.sessions.map(\.sessionId) == ["s-profile", "s-ok"])
        #expect(result.sessions[1] == ClaudeSessionSummary(
            sessionId: "s-ok", title: "Demo", cwd: "/Users/example/demo", gitBranch: "main", status: "idle",
            createdAt: 1_794_214_800_000, modifiedAt: 1_794_218_400_000
        ))
        #expect(await vault.calls == [.object(["agent": .string("claude"), "limit": .int(50)])])
        let encoded = String(decoding: try SharedKitJSON.snakeCaseEncoder.encode(result), as: UTF8.self)
        for hidden in ["\"file\"", "resume", layout.sandbox.base.path, ".jsonl"] {
            #expect(!encoded.contains(hidden), "\(hidden)")
        }
        #expect(log.lines == ["claude.sessions.list kept=2 dropped: not_claude=1 invalid_id=1 no_file=1 refused=7"])
    }

    @Test func openerRefusesEachUnsafeShapeWithoutOpeningIt() throws {
        let layout = try layout()
        defer { layout.sandbox.remove() }
        let root = layout.sandbox.root.path
        func refusal(_ path: String) -> ClaudeTranscriptFileOpener.Refusal? {
            switch ClaudeTranscriptFileOpener.open(path, root: root) {
            case .success(let file): _ = Darwin.close(file.descriptor); return nil
            case .failure(let refusal): return refusal
            }
        }

        #expect(refusal(layout.ok.path) == nil)
        #expect(refusal(layout.profilePath) == nil)
        #expect(refusal(layout.escape.path) == .outsideRoot)
        #expect(refusal(layout.sandbox.outside.appendingPathComponent("s-outside.jsonl").path) == .outsideRoot)
        #expect(refusal(layout.fifo.path) == .notRegularFile)
        #expect(refusal(layout.directory.path) == .notRegularFile)
        #expect(refusal(layout.dotdot) == .badPath)
        #expect(refusal(layout.text.path) == .notJSONL)
        #expect(refusal(layout.deep.path) == .outsideRoot)
        #expect(refusal("relative/s-ok.jsonl") == .badPath)
        #expect(refusal(layout.sandbox.project.appendingPathComponent("missing.jsonl").path) == .missing)
    }

    @Test func pageReadsAnAllowedSessionAndRefusesEveryOtherId() async throws {
        let layout = try layout()
        defer { layout.sandbox.remove() }
        let vault = FakeVaultCMUX(sessions: layout.sessions)
        let service = layout.sandbox.service(vault)

        let page = try await service.page(ClaudeTranscriptPageRequest(sessionId: "s-ok"))
        #expect(page.entries.map(\.id) == ["u1", "a1"])
        #expect(page.before == nil)
        #expect(page.fileSize == Int64(try Data(contentsOf: layout.ok).count))
        #expect(await vault.calls.count == 1)
        #expect(try await service.page(ClaudeTranscriptPageRequest(sessionId: "s-ok", before: page.fileSize, maxEntries: 1)).entries.map(\.id) == ["a1"])
        #expect(await vault.calls.count == 1)

        for id in ["s-escape", "s-fifo", "s-dir", "s-text", "s-outside", "s-nofile", "s-dotdot", "s-deep", "s-codex", "unknown"] {
            await #expect(throws: ClaudeTranscriptService.Error.sessionNotFound) {
                try await service.page(ClaudeTranscriptPageRequest(sessionId: id))
            }
        }
        #expect(await vault.calls.count == 11)
        await #expect(throws: ClaudeTranscriptService.Error.invalidField("before")) {
            try await service.page(ClaudeTranscriptPageRequest(sessionId: "s-ok", before: page.fileSize + 1))
        }
    }

    @Test func fileSwappedForAnEscapingSymlinkAfterListingIsRefused() async throws {
        let layout = try layout()
        defer { layout.sandbox.remove() }
        let service = layout.sandbox.service(FakeVaultCMUX(sessions: layout.sessions))
        _ = try await service.sessions(limit: 50)

        try FileManager.default.removeItem(at: layout.ok)
        try FileManager.default.createSymbolicLink(at: layout.ok, withDestinationURL: layout.sandbox.outside.appendingPathComponent("s-outside.jsonl"))

        await #expect(throws: ClaudeTranscriptService.Error.sessionNotFound) {
            try await service.page(ClaudeTranscriptPageRequest(sessionId: "s-ok"))
        }
    }

    @Test func pathCacheLastsSixtySecondsThenAsksVaultAgain() async throws {
        let layout = try layout()
        defer { layout.sandbox.remove() }
        let vault = FakeVaultCMUX(sessions: layout.sessions)
        let clock = TestClock(Date(timeIntervalSince1970: 1_794_240_000))
        let service = layout.sandbox.service(vault, clock: clock)

        _ = try await service.sessions(limit: 50)
        clock.advance(59)
        _ = try await service.page(ClaudeTranscriptPageRequest(sessionId: "s-ok"))
        #expect(await vault.calls.count == 1)
        clock.advance(2)
        _ = try await service.page(ClaudeTranscriptPageRequest(sessionId: "s-ok"))
        #expect(await vault.calls.count == 2)
        #expect(await vault.calls.last == .object(["agent": .string("claude"), "limit": .int(100)]))
    }

    @Test func vaultFailuresKeepTheirCodes() async throws {
        let sandbox = try TranscriptSandbox()
        defer { sandbox.remove() }
        await #expect(throws: ClaudeTranscriptService.Error.native("rate_limited")) {
            try await sandbox.service(FakeVaultCMUX(sessions: [], failure: "rate_limited")).sessions(limit: 10)
        }
        await #expect(throws: ClaudeTranscriptService.Error.native("forbidden")) {
            try await sandbox.service(FakeVaultCMUX(sessions: [], failure: "unauthorized")).sessions(limit: 10)
        }
        let noRoot = ClaudeTranscriptService(dispatch: FakeVaultCMUX(sessions: []).dispatch, root: nil, log: { _ in })
        await #expect(throws: ClaudeTranscriptService.Error.sessionNotFound) {
            try await noRoot.page(ClaudeTranscriptPageRequest(sessionId: "s-ok"))
        }
    }

    @Test func pageStaysUnderEncodedBudgetAndBeforeAdvances() async throws {
        let sandbox = try TranscriptSandbox()
        defer { sandbox.remove() }
        let quoted = String(repeating: "\"", count: ClaudeTranscriptLimits.maxTextBytes - 16)
        let url = try sandbox.write(sandbox.project.appendingPathComponent("big.jsonl"),
                                    (0..<100).map { TranscriptLine.user("u\($0)", "\($0) " + quoted) })
        let service = sandbox.service(FakeVaultCMUX(sessions: [TranscriptLine.vaultSession("big", file: url.path)]))

        var pages: [ClaudeTranscriptPageResult] = []
        var before: Int64?
        repeat {
            let page = try await service.page(ClaudeTranscriptPageRequest(sessionId: "big", before: before, maxEntries: 100))
            let response = RPCResponse(id: "p", ok: true, result: try JSONDecoder().decode(
                JSONValue.self, from: SharedKitJSON.snakeCaseEncoder.encode(page)
            ))
            #expect(try SharedKitJSON.snakeCaseEncoder.encode(page).count <= Self.budget)
            #expect(try SharedKitJSON.deterministicEncoder.encode(response).count <= ClaudeTranscriptLimits.maxResponseBytes)
            if let previous = before, let next = page.before { #expect(next < previous) }
            pages.append(page)
            before = page.before
        } while before != nil && pages.count < 100

        #expect(pages.count > 1)
        #expect(pages[0].entries.count < 100)
        #expect(pages.reversed().flatMap(\.entries).map(\.id) == (0..<100).map { "u\($0)" })
    }

    @Test func logsCarryNoTranscriptContent() async throws {
        let sandbox = try TranscriptSandbox()
        defer { sandbox.remove() }
        let marker = "SECRET-MARKER"
        let url = try sandbox.write(sandbox.project.appendingPathComponent("marked.jsonl"), [
            TranscriptLine.user("u-\(marker)", "text \(marker)"),
            TranscriptLine.assistant("a", messageId: "m-\(marker)", [["type": "tool_use", "id": "t", "name": "Bash", "input": ["command": marker]]]),
            Data("{broken \(marker)\n".utf8),
            TranscriptLine.user("huge", String(repeating: "x", count: 5 * 1_024 * 1_024)),
        ])
        let vault = FakeVaultCMUX(sessions: [
            TranscriptLine.vaultSession("marked", file: url.path, title: "title \(marker)", cwd: "/cwd/\(marker)"),
            TranscriptLine.vaultSession("outside", file: "/tmp/\(marker).jsonl", title: marker),
        ])
        let log = BrowserLogRecorder()
        let service = sandbox.service(vault, log: log)

        _ = try await service.sessions(limit: 10)
        _ = try await service.page(ClaudeTranscriptPageRequest(sessionId: "marked"))
        await #expect(throws: ClaudeTranscriptService.Error.sessionNotFound) {
            try await service.page(ClaudeTranscriptPageRequest(sessionId: "outside"))
        }

        #expect(log.lines.count == 4)
        #expect(log.lines.contains { $0.contains("skipped_long=1 broken=1") })
        for line in log.lines {
            #expect(!line.contains(marker))
            #expect(!line.contains("/"))
            #expect(!line.contains("marked"))
        }
    }
}
