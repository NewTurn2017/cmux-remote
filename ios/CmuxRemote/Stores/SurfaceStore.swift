import Foundation
import Observation
import SharedKit

@MainActor
@Observable
public final class SurfaceStore {
    public static let defaultSubscriptionLines = 120

    public var grid: CellGrid = CellGrid(cols: 80, rows: 24)
    public var rev: Int = 0
    public var subscribed: String?
    public var subscribedWorkspaceId: String?
    public var inputStatus: TerminalInputStatus = .idle

    private let rpc: any RPCDispatch

    public init(rpc: any RPCDispatch) {
        self.rpc = rpc
    }

    public func subscribe(workspaceId: String, surfaceId: String) async {
        if let current = subscribed, current != surfaceId {
            await unsubscribe(surfaceId: current)
        }
        subscribed = surfaceId
        subscribedWorkspaceId = workspaceId
        _ = try? await rpc.call(
            method: "surface.subscribe",
            params: .object([
                "workspace_id": .string(workspaceId),
                "surface_id": .string(surfaceId),
                "fps": .int(15),
                "lines": .int(Int64(Self.defaultSubscriptionLines)),
            ])
        )
        await focusCurrentSurface()
        await requestFull(surfaceId: surfaceId)
    }

    public func resubscribe() async {
        guard let workspaceId = subscribedWorkspaceId, let surfaceId = subscribed else { return }
        _ = try? await rpc.call(
            method: "surface.subscribe",
            params: .object([
                "workspace_id": .string(workspaceId),
                "surface_id": .string(surfaceId),
                "fps": .int(15),
                "lines": .int(Int64(Self.defaultSubscriptionLines)),
            ])
        )
        await focusCurrentSurface()
        await requestFull(surfaceId: surfaceId)
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
            var replacement = grid
            if grid.cols != frame.cols
                || grid.rows.count != frame.rowsCount
                || frame.rows.count != frame.rowsCount
            {
                replacement = CellGrid(cols: frame.cols, rows: frame.rowsCount)
            }
            for (index, row) in frame.rows.enumerated() {
                replacement.replaceRow(index, raw: row)
            }
            replacement.cursor = frame.cursor
            grid = replacement
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
                ? "Sent text"
                : "Sent \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
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
            inputStatus = .sent("Attached \(payload.filename)")
            return payload
        } catch {
            inputStatus = .failed(String(describing: error))
            throw error
        }
    }

    public func submitCommand(workspaceId: String, surfaceId: String, command: String) async throws {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleLine = trimmed.map { $0.isNewline ? " " : String($0) }.joined()
        guard !singleLine.isEmpty else {
            try await sendKey(workspaceId: workspaceId, surfaceId: surfaceId, key: .enter)
            return
        }
        try await dispatchInput(successMessage: "Sent \(singleLine)") {
            _ = try await rpc.call(
                method: "surface.send_text",
                params: .object([
                    "workspace_id": .string(workspaceId),
                    "surface_id": .string(surfaceId),
                    "text": .string(singleLine),
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
        try await dispatchInput(successMessage: "Sent \(encoded)") {
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
                "lines": .int(Int64(max(grid.rawRows.count, Self.defaultSubscriptionLines))),
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
            return "Sending…"
        case .sent(let text), .failed(let text):
            return text
        }
    }

    public var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}
