import Darwin
import Foundation
import Logging
import SharedKit

/// Serves `claude.sessions.list` and `claude.transcript.page` from cmux `vault.sessions` and the
/// session's JSONL file.
///
/// The phone only ever sends a session id. The relay maps it to a file path from vault, keeps
/// only paths that pass ``ClaudeTranscriptFileOpener``, and never returns the path or resume
/// command. File work runs off the cooperative pool. Log lines carry counts, bytes, and times only.
actor ClaudeTranscriptService {
    typealias Dispatch = @Sendable (String, JSONValue) async -> TerminalArtifactService.NativeResult

    enum Error: Swift.Error, Sendable, Equatable {
        case sessionNotFound
        case invalidField(String)
        case fileChanged
        case malformed
        case native(String)
    }

    static let pathCacheLifetime: TimeInterval = 60
    static let pathCacheCapacity = 512
    static let logger = Logger(label: "cmux-relay.claude-transcript")

    private static let responseBudget = ClaudeTranscriptLimits.maxResponseBytes - ClaudeTranscriptLimits.responseEnvelopeReserveBytes

    private let dispatch: Dispatch
    private let root: String?
    private let clock: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private let readLimits: ClaudeTranscriptReader.Limits
    private var paths: [String: (path: String, at: Date)] = [:]

    init(
        dispatch: @escaping Dispatch,
        root: String?,
        clock: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (String) -> Void = { ClaudeTranscriptService.logger.notice("\($0)") },
        readLimits: ClaudeTranscriptReader.Limits = ClaudeTranscriptReader.Limits()
    ) {
        self.dispatch = dispatch
        self.root = root
        self.clock = clock
        self.log = log
        self.readLimits = readLimits
    }

    init(cmux: any CMUXFacade) {
        self.init(dispatch: { method, params in
            do {
                return .success(try await cmux.dispatch(method: method, params: params))
            } catch let error as RPCError {
                return .failure(code: error.code)
            } catch {
                return .failure(code: "internal_error")
            }
        }, root: ClaudeTranscriptFileOpener.defaultRoot())
    }

    // MARK: - Sessions

    func sessions(limit: Int) async throws -> ClaudeSessionListResult {
        let allowed = try await fetchAllowedSessions(limit: limit)
        let sorted = allowed.map(\.summary).sorted { ($0.modifiedAt ?? 0) > ($1.modifiedAt ?? 0) }
        var kept: [ClaudeSessionSummary] = []
        var used = (try? SharedKitJSON.snakeCaseEncoder.encode(ClaudeSessionListResult(sessions: [])).count) ?? 0
        for summary in sorted.prefix(limit) {
            let size = ((try? SharedKitJSON.snakeCaseEncoder.encode(summary).count) ?? Self.responseBudget) + 1
            guard used + size <= Self.responseBudget else { break }
            kept.append(summary)
            used += size
        }
        if kept.count < min(sorted.count, limit) {
            log("claude.sessions.list truncated: kept=\(kept.count) omitted=\(min(sorted.count, limit) - kept.count)")
        }
        return ClaudeSessionListResult(sessions: kept)
    }

    // MARK: - Transcript page

    func page(_ request: ClaudeTranscriptPageRequest) async throws -> ClaudeTranscriptPageResult {
        guard let root else {
            log("claude.transcript.page refused: no_root")
            throw Error.sessionNotFound
        }
        var path = cachedPath(request.sessionId)
        if path == nil {
            _ = try await fetchAllowedSessions(limit: ClaudeTranscriptLimits.maxSessionLimit)
            path = cachedPath(request.sessionId)
        }
        guard let path else {
            log("claude.transcript.page refused: unknown_session")
            throw Error.sessionNotFound
        }

        let maxEntries = request.maxEntries ?? ClaudeTranscriptLimits.defaultPageEntries
        let limits = readLimits
        let sessionId = request.sessionId
        let started = clock()
        let outcome = await BoundedRelayWork.offCooperativePool { () -> Result<(ClaudeTranscriptReader.Page, Int64), Error> in
            let file: ClaudeTranscriptFileOpener.OpenedFile
            switch ClaudeTranscriptFileOpener.open(path, root: root) {
            case .success(let opened): file = opened
            case .failure: return .failure(.sessionNotFound)
            }
            defer { _ = Darwin.close(file.descriptor) }
            if let before = request.before, before > file.size { return .failure(.invalidField("before")) }
            let base = (try? SharedKitJSON.snakeCaseEncoder.encode(ClaudeTranscriptPageResult(
                sessionId: sessionId, entries: [], before: file.size, fileSize: file.size
            )).count) ?? 0
            do {
                let page = try ClaudeTranscriptReader.readPage(
                    descriptor: file.descriptor,
                    end: request.before ?? file.size,
                    maxEntries: maxEntries,
                    entryBytesBudget: Self.responseBudget - base,
                    limits: limits
                )
                return .success((page, file.size))
            } catch {
                return .failure(.fileChanged)
            }
        }

        switch outcome {
        case .failure(let error):
            if error == .sessionNotFound { paths[sessionId] = nil }
            log("claude.transcript.page refused: \(Self.reason(error))")
            throw error
        case .success(let (page, fileSize)):
            let milliseconds = Int((clock().timeIntervalSince(started) * 1_000).rounded())
            log("claude.transcript.page entries=\(page.entries.count) bytes_read=\(page.scan.bytesRead) skipped_long=\(page.scan.skippedLongLines) broken=\(page.brokenLines) ms=\(milliseconds)")
            return ClaudeTranscriptPageResult(sessionId: sessionId, entries: page.entries, before: page.before, fileSize: fileSize)
        }
    }

    // MARK: - Vault

    private struct AllowedSession {
        let summary: ClaudeSessionSummary
        let path: String
    }

    private enum Drop: String, CaseIterable, Swift.Error {
        case notClaude = "not_claude"
        case invalidId = "invalid_id"
        case noFile = "no_file"
        case refused
    }

    private func fetchAllowedSessions(limit: Int) async throws -> [AllowedSession] {
        let rawSessions: [JSONValue]
        switch await dispatch("vault.sessions", .object(["agent": .string("claude"), "limit": .int(Int64(limit))])) {
        case .success(.object(let fields)):
            switch fields["sessions"] {
            case nil, .null?: rawSessions = []
            case .array(let sessions)?: rawSessions = sessions
            default:
                log("claude.sessions.list refused: malformed_response")
                throw Error.malformed
            }
        case .success:
            log("claude.sessions.list refused: malformed_response")
            throw Error.malformed
        case .failure(let code):
            log("claude.sessions.list cmux error: code=\(Self.loggableCode(code))")
            throw Self.mapFailure(code)
        }

        let root = self.root
        let (allowed, drops) = await BoundedRelayWork.offCooperativePool { () -> ([AllowedSession], [Drop: Int]) in
            var allowed: [AllowedSession] = []
            var drops: [Drop: Int] = [:]
            for raw in rawSessions {
                switch Self.allowedSession(raw, root: root) {
                case .success(let session): allowed.append(session)
                case .failure(let drop): drops[drop, default: 0] += 1
                }
            }
            return (allowed, drops)
        }

        let now = clock()
        for session in allowed { remember(session.summary.sessionId, path: session.path, at: now) }
        let counts = Drop.allCases.compactMap { drop in drops[drop].map { "\(drop.rawValue)=\($0)" } }
        log("claude.sessions.list kept=\(allowed.count)" + (counts.isEmpty ? "" : " dropped: " + counts.joined(separator: " ")))
        return allowed
    }

    private static func allowedSession(_ raw: JSONValue, root: String?) -> Result<AllowedSession, Drop> {
        guard case .object(let fields) = raw else { return .failure(.invalidId) }
        func text(_ key: String) -> String? {
            guard case .string(let value)? = fields[key], !value.isEmpty else { return nil }
            return value
        }
        guard text("agent") == "claude" else { return .failure(.notClaude) }
        guard let sessionId = text("session_id"), ClaudeTranscriptLimits.isValidSessionId(sessionId) else {
            return .failure(.invalidId)
        }
        guard let file = text("file") else { return .failure(.noFile) }
        guard let root, case .success(let path) = ClaudeTranscriptFileOpener.allowedRealPath(file, root: root) else {
            return .failure(.refused)
        }
        let summary = ClaudeSessionSummary(
            sessionId: sessionId,
            title: text("title").map { FeedItemTranslator.cut($0, maxCharacters: ClaudeTranscriptLimits.maxSessionTitleCharacters).text },
            cwd: text("cwd").map { FeedItemTranslator.cut($0, maxCharacters: ClaudeTranscriptLimits.maxCwdCharacters).text },
            gitBranch: text("git_branch").map { FeedItemTranslator.cut($0, maxCharacters: ClaudeTranscriptLimits.maxGitBranchCharacters).text },
            status: text("status").map { FeedItemTranslator.cut($0, maxCharacters: ClaudeTranscriptLimits.maxStatusCharacters).text },
            createdAt: epochMilliseconds(text("created")),
            modifiedAt: epochMilliseconds(text("modified"))
        )
        return .success(AllowedSession(summary: summary, path: path))
    }

    // MARK: - Path cache

    private func cachedPath(_ sessionId: String) -> String? {
        guard let cached = paths[sessionId] else { return nil }
        let age = clock().timeIntervalSince(cached.at)
        guard age >= 0, age < Self.pathCacheLifetime else {
            paths[sessionId] = nil
            return nil
        }
        return cached.path
    }

    private func remember(_ sessionId: String, path: String, at: Date) {
        paths[sessionId] = (path, at)
        guard paths.count > Self.pathCacheCapacity else { return }
        let oldest = paths.sorted { $0.value.at < $1.value.at }.prefix(paths.count - Self.pathCacheCapacity)
        for (key, _) in oldest { paths[key] = nil }
    }

    // MARK: - Helpers

    private static func epochMilliseconds(_ raw: String?) -> Int64? {
        guard let raw else { return nil }
        let date = (try? Date(raw, strategy: .iso8601))
            ?? (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        return date.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) }
    }

    private static func reason(_ error: Error) -> String {
        switch error {
        case .sessionNotFound: return "not_found"
        case .invalidField: return "invalid_field"
        case .fileChanged: return "file_changed"
        case .malformed: return "malformed_response"
        case .native: return "cmux_error"
        }
    }

    private static func mapFailure(_ code: String) -> Error {
        switch code {
        case "unauthorized", "forbidden": return .native("forbidden")
        default: return .native(code)
        }
    }

    private static func loggableCode(_ code: String) -> String {
        let allowed = code.count <= 64 && !code.isEmpty && code.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
        }
        return allowed ? code : "other"
    }
}
