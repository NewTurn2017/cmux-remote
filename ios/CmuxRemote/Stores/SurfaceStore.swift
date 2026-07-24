import Foundation
import Observation
import SharedKit

@MainActor
@Observable
public final class SurfaceStore {
    public static let defaultSubscriptionLines = 120
    static let liveHistoryAnchorID = "terminal-live-anchor"

    public var grid: CellGrid = CellGrid(cols: 80, rows: 24)
    public var rev: Int = 0
    public var subscribed: String?
    public var subscribedWorkspaceId: String?
    public var inputStatus: TerminalInputStatus = .idle
    private(set) var historyPages: [TerminalHistoryPage] = []
    var historyRows: [String] { historyPages.flatMap(\.rows) }
    public private(set) var historyAnchorRows: [String]?
    public private(set) var historyNextCursor: String?
    private(set) var historyRestoreAnchorID: String?
    public private(set) var historyLoadGeneration: Int = 0
    public private(set) var isLoadingOlderHistory = false
    public private(set) var historyUnavailable = false

    private let rpc: any RPCDispatch

    public init(rpc: any RPCDispatch) {
        self.rpc = rpc
    }

    public func subscribe(workspaceId: String, surfaceId: String) async {
        if let current = subscribed, current != surfaceId {
            await unsubscribe(surfaceId: current)
        }
        clearHistorySnapshot()
        subscribed = surfaceId
        subscribedWorkspaceId = workspaceId
        _ = try? await rpc.call(
            method: "surface.subscribe",
            params: .object([
                "workspace_id": .string(workspaceId),
                "surface_id": .string(surfaceId),
                "fps": .int(15),
                "lines": .int(Int64(subscriptionLines)),
            ])
        )
        await focusCurrentSurface()
        await requestFull(surfaceId: surfaceId)
    }

    public func resubscribe() async {
        guard let workspaceId = subscribedWorkspaceId, let surfaceId = subscribed else { return }
        clearHistorySnapshot()
        _ = try? await rpc.call(
            method: "surface.subscribe",
            params: .object([
                "workspace_id": .string(workspaceId),
                "surface_id": .string(surfaceId),
                "fps": .int(15),
                "lines": .int(Int64(subscriptionLines)),
            ])
        )
        await focusCurrentSurface()
        await requestFull(surfaceId: surfaceId)
    }

    /// Apply a changed terminal-history preference to an already subscribed
    /// surface. The relay owns the subscription shape, so it must be replaced
    /// rather than merely asking for another full frame.
    public func refreshSubscriptionPreferences() async {
        guard let workspaceId = subscribedWorkspaceId, let surfaceId = subscribed else { return }
        await unsubscribe(surfaceId: surfaceId)
        await subscribe(workspaceId: workspaceId, surfaceId: surfaceId)
    }

    /// Starts (or continues) an immutable, cursor-based scrollback snapshot.
    /// The live grid keeps receiving frames in the background; once history is
    /// opened the view renders the stable anchor supplied by the relay so
    /// incoming output cannot make the reader lose their place.
    public func loadOlderHistory() async {
        guard let workspaceId = subscribedWorkspaceId, let surfaceId = subscribed else { return }
        guard !isLoadingOlderHistory else { return }
        guard !historyUnavailable else { return }

        let isFirstPage = historyAnchorRows == nil
        guard isFirstPage || historyNextCursor != nil else { return }

        isLoadingOlderHistory = true
        defer { isLoadingOlderHistory = false }

        do {
            var params: [String: JSONValue] = [
                "workspace_id": .string(workspaceId),
                "surface_id": .string(surfaceId),
                "tail_lines": .int(Int64(max(grid.rawRows.count, subscriptionLines))),
                "limit": .int(200),
            ]
            if let historyNextCursor {
                params["cursor"] = .string(historyNextCursor)
            }
            let response = try await rpc.call(method: "surface.history", params: .object(params))
            let page = try response.unwrapResult().decode(SurfaceHistoryPagePayload.self)

            if isFirstPage {
                let anchorRows = page.anchorRows ?? grid.rawRows
                historyPages = [TerminalHistoryPage(rows: page.rows)]
                historyAnchorRows = anchorRows
                historyRestoreAnchorID = Self.liveHistoryAnchorID
            } else {
                historyRestoreAnchorID = historyPages.first?.id ?? Self.liveHistoryAnchorID
                historyPages.insert(TerminalHistoryPage(rows: page.rows), at: 0)
            }
            historyNextCursor = page.nextCursor
            historyLoadGeneration &+= 1
        } catch {
            historyUnavailable = true
            inputStatus = .failed(String(describing: error))
        }
    }

    /// Return to the current terminal frame after browsing a frozen history
    /// snapshot. The latest live grid has continued updating in the meantime.
    public func resumeLiveHistory() {
        clearHistorySnapshot()
    }

    /// Pin cmux's pane focus to the surface we're viewing — without it, key
    /// input lands wherever the desktop cmux window last focused, so the
    /// iPhone's arrow keys can dead-end in a chat REPL while a TUI in a
    /// sibling pane is the one the user actually sees.
    public func focusCurrentSurface() async {
        guard let workspaceId = subscribedWorkspaceId, let surfaceId = subscribed else { return }
        _ = try? await rpc.call(
            method: "surface.focus",
            params: .object([
                "workspace_id": .string(workspaceId),
                "surface_id": .string(surfaceId),
            ])
        )
    }

    public func unsubscribe(surfaceId: String) async {
        _ = try? await rpc.call(method: "surface.unsubscribe", params: .object(["surface_id": .string(surfaceId)]))
        if subscribed == surfaceId {
            subscribed = nil
            subscribedWorkspaceId = nil
        }
    }

    public func ingest(_ frame: PushFrame) {
        switch frame {
        case .screenFull(let frame):
            guard frame.surfaceId == subscribed || subscribed == nil else { return }
            grid = CellGrid(cols: frame.cols, rows: frame.rowsCount)
            for (index, row) in frame.rows.enumerated() { grid.replaceRow(index, raw: row) }
            grid.cursor = frame.cursor
            rev = frame.rev
        case .screenDiff(let frame):
            guard frame.surfaceId == subscribed || subscribed == nil else { return }
            for op in frame.ops {
                switch op {
                case .clear:
                    grid.clear()
                case .row(let y, let text):
                    grid.replaceRow(y, raw: text)
                case .cursor(let x, let y):
                    grid.cursor = CursorPos(x: x, y: y)
                }
            }
            rev = frame.rev
        case .screenChecksum(let frame):
            guard frame.surfaceId == subscribed else { return }
            let computed = ScreenHasher.hash(currentScreen())
            if computed != frame.hash {
                Task { await self.requestFull(surfaceId: frame.surfaceId) }
            }
        default:
            break
        }
    }

    public func sendText(workspaceId: String, surfaceId: String, text: String) async throws {
        try await dispatchInput(
            successMessage: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? L10n.string("Sent text")
                : L10n.format("Sent %@", text.trimmingCharacters(in: .whitespacesAndNewlines))
        ) {
            try await rpc.call(
                method: "surface.send_text",
                params: .object([
                    "workspace_id": .string(workspaceId),
                    "surface_id": .string(surfaceId),
                    "text": .string(text),
                ])
            ).requireOk()
        }
    }

    public func uploadFile(data: Data, filename: String, mimeType: String) async throws -> UploadedFilePayload {
        inputStatus = .sending
        do {
            let response = try await rpc.call(
                method: "file.upload",
                params: .object([
                    "filename": .string(filename),
                    "mime_type": .string(mimeType),
                    "data_base64": .string(data.base64EncodedString()),
                ])
            ).requireOk()
            let payload = try response.unwrapResult().decode(UploadedFilePayload.self)
            inputStatus = .sent(L10n.format("Attached %@", payload.filename))
            return payload
        } catch {
            inputStatus = .failed(String(describing: error))
            throw error
        }
    }

    public func submitCommand(workspaceId: String, surfaceId: String, command: String) async throws {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try await sendKey(workspaceId: workspaceId, surfaceId: surfaceId, key: .enter)
            return
        }
        try await dispatchInput(successMessage: L10n.format("Sent %@", trimmed)) {
            _ = try await rpc.call(
                method: "surface.send_text",
                params: .object([
                    "workspace_id": .string(workspaceId),
                    "surface_id": .string(surfaceId),
                    "text": .string(trimmed),
                ])
            ).requireOk()
            return try await rpc.call(
                method: "surface.send_key",
                params: .object([
                    "workspace_id": .string(workspaceId),
                    "surface_id": .string(surfaceId),
                    "key": .string(KeyEncoder.encode(.enter)),
                ])
            ).requireOk()
        }
    }

    public func sendKey(workspaceId: String, surfaceId: String, key: Key) async throws {
        let encoded = KeyEncoder.encode(key)
        try await dispatchInput(successMessage: L10n.format("Sent %@", encoded)) {
            // cmux's `surface.send_key` synthesizes one NSEvent so multi-byte
            // sequences (arrows, ctrl combos) arrive atomically — vital for
            // Ink-based TUIs (Claude Code) whose ESC parser fires on the
            // standalone ESC byte if the rest of the sequence is even a few
            // ms behind. The synth event only lands when the surface is the
            // focused one in cmux, so re-pin focus right before the send.
            _ = try? await rpc.call(
                method: "surface.focus",
                params: .object([
                    "workspace_id": .string(workspaceId),
                    "surface_id": .string(surfaceId),
                ])
            )
            return try await rpc.call(
                method: "surface.send_key",
                params: .object([
                    "workspace_id": .string(workspaceId),
                    "surface_id": .string(surfaceId),
                    "key": .string(encoded),
                ])
            ).requireOk()
        }
    }

    public func reset() {
        grid = CellGrid(cols: 80, rows: 24)
        rev = 0
        subscribed = nil
        subscribedWorkspaceId = nil
        inputStatus = .idle
        clearHistorySnapshot()
    }

    private func dispatchInput(
        successMessage: String,
        operation: () async throws -> RPCResponse
    ) async throws {
        inputStatus = .sending
        do {
            _ = try await operation()
            inputStatus = .sent(successMessage)
        } catch {
            inputStatus = .failed(String(describing: error))
            throw error
        }
    }

    private func requestFull(surfaceId: String) async {
        guard let workspaceId = subscribedWorkspaceId else { return }
        guard let response = try? await rpc.call(
            method: "surface.read_text",
            params: .object([
                "workspace_id": .string(workspaceId),
                "surface_id": .string(surfaceId),
                "lines": .int(Int64(max(grid.rawRows.count, subscriptionLines))),
            ])
        ),
        let payload = try? response.unwrapResult().decode(ReadTextPayload.self)
        else { return }

        let screen = payload.screen(rev: rev + 1)
        grid = CellGrid(cols: screen.cols, rows: screen.rows.count)
        for (index, row) in screen.rows.enumerated() { grid.replaceRow(index, raw: row) }
        grid.cursor = screen.cursor
        rev = screen.rev
    }

    private func currentScreen() -> Screen {
        Screen(
            rev: rev,
            rows: grid.rawRows,
            cols: grid.cols,
            cursor: grid.cursor
        )
    }

    private var subscriptionLines: Int {
        let configured = UserDefaults.standard.integer(forKey: "cmux.terminalHistoryLines")
        return min(max(configured == 0 ? Self.defaultSubscriptionLines : configured, 60), 400)
    }

    private func clearHistorySnapshot() {
        historyPages = []
        historyAnchorRows = nil
        historyNextCursor = nil
        historyRestoreAnchorID = nil
        historyUnavailable = false
        historyLoadGeneration &+= 1
    }
}

struct TerminalHistoryPage: Identifiable {
    let id = UUID().uuidString
    let rows: [String]

    init(rows: [String]) {
        self.rows = rows
    }
}

public enum TerminalInputStatus: Equatable {
    case idle
    case sending
    case sent(String)
    case failed(String)

    public var message: String? {
        switch self {
        case .idle:
            return nil
        case .sending:
            return L10n.string("Sending…")
        case .sent(let text), .failed(let text):
            return text
        }
    }

    public var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}
