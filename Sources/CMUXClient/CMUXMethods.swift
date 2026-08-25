import Foundation
import SharedKit

extension CMUXClient {
    /// Fetches the capabilities and methods advertised by the connected daemon.
    ///
    /// - Returns: The daemon's capability identifiers and RPC method names.
    /// - Throws: ``CMUXClientError`` when dispatch fails or ``CMUXTerminalSourceError/malformedCapabilities(_:)`` for malformed arrays.
    public func capabilities() async throws -> CMUXCapabilities {
        let response = try await call(method: "system.capabilities", params: .object([:]))
        let result = try response.unwrapResult()
        do {
            return try result.decode(CMUXCapabilities.self)
        } catch {
            throw CMUXTerminalSourceError.malformedCapabilities(String(describing: error))
        }
    }

    public func workspaceList() async throws -> [Workspace] {
        let resp = try await call(method: "workspace.list", params: .object([:]))
        let raw = try resp.unwrapResult().decode(CMUXWorkspaceListRaw.self)
        return raw.workspaces.map { $0.toWorkspace() }
    }

    public func workspaceCreate(name: String) async throws -> Workspace {
        let resp = try await call(method: "workspace.create",
                                  params: .object(["title": .string(name)]))
        let raw = try resp.unwrapResult().decode(CMUXWorkspaceCreateRaw.self)
        return raw.workspace.toWorkspace()
    }

    public func workspaceRename(id: String, title: String) async throws {
        _ = try await call(method: "workspace.rename",
                           params: .object([
                               "workspace_id": .string(id),
                               "title": .string(title),
                           ])).requireOk()
    }

    public func workspaceSelect(id: String) async throws {
        _ = try await call(method: "workspace.select",
                           params: .object(["workspace_id": .string(id)])).requireOk()
    }

    public func workspaceClose(id: String) async throws {
        _ = try await call(method: "workspace.close",
                           params: .object(["workspace_id": .string(id)])).requireOk()
    }

    public func surfaceList(workspaceId: String) async throws -> [Surface] {
        let resp = try await call(method: "surface.list",
                                  params: .object(["workspace_id": .string(workspaceId)]))
        let raw = try resp.unwrapResult().decode(CMUXSurfaceListRaw.self)
        return raw.surfaces.map { $0.toSurface() }
    }

    public func surfaceSendText(workspaceId: String, surfaceId: String, text: String) async throws {
        _ = try await call(method: "surface.send_text",
                           params: .object([
                               "workspace_id": .string(workspaceId),
                               "surface_id": .string(surfaceId),
                               "text": .string(text),
                           ])).requireOk()
    }

    public func surfaceSendKey(workspaceId: String, surfaceId: String, key: Key) async throws {
        let encoded = KeyEncoder.encode(key)
        _ = try await call(method: "surface.send_key",
                           params: .object([
                               "workspace_id": .string(workspaceId),
                               "surface_id": .string(surfaceId),
                               "key": .string(encoded),
                           ])).requireOk()
    }

    public func surfaceReadText(workspaceId: String, surfaceId: String, lines: Int)
        async throws -> Screen
    {
        guard lines >= 0 else {
            throw CMUXClientError.decoding("surface.read_text lines must be nonnegative")
        }
        let resp = try await call(method: "surface.read_text",
                                  params: .object([
                                      "workspace_id": .string(workspaceId),
                                      "surface_id": .string(surfaceId),
                                      "lines": .int(Int64(lines)),
                                  ]))
        let raw = try resp.unwrapResult().decode(CMUXReadTextRaw.self)
        // `rev` is a relay-internal counter (DiffEngine bumps per tick); the
        // cmux response has no equivalent, so we hand back 0 here and let
        // callers stamp their own rev.
        return raw.toScreen(rev: 0)
    }

    /// Reads one authoritative terminal source snapshot without starting a polling loop.
    ///
    /// - Parameters:
    ///   - workspaceId: Expected workspace identifier for response validation.
    ///   - surfaceId: Surface whose viewport should be read.
    ///   - lines: Legacy plain-text line count used only when replay is unsupported.
    /// - Returns: A new screen, an explicit unchanged result, or a typed stale result.
    /// - Throws: ``CMUXClientError`` for dispatch failures or ``CMUXTerminalSourceError`` for malformed source data.
    public func terminalRead(
        workspaceId: String,
        surfaceId: String,
        lines: Int
    ) async throws -> CMUXTerminalReadOutcome {
        guard lines >= 0 else {
            throw CMUXClientError.decoding("terminal read lines must be nonnegative")
        }

        let sourceMode = try await terminalSourceMode()

        switch sourceMode {
        case .legacyText:
            let screen = try await surfaceReadText(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                lines: lines
            )
            return .updated(CMUXTerminalReadUpdate(
                screen: screen,
                sourceMode: .legacyText,
                replayIdentity: nil
            ))

        case .renderGrid:
            let replay = try await terminalReplay(surfaceId: surfaceId)
            try replay.validate(workspaceId: workspaceId, surfaceId: surfaceId)
            let identity = replay.identity
            let continuityKey = CMUXTerminalContinuityState.key(
                workspaceId: workspaceId,
                surfaceId: surfaceId
            )
            switch terminalContinuityState.classify(identity: identity, key: continuityKey) {
            case .unchanged:
                return .unchanged(identity)
            case .ignored(let reason):
                return .ignored(reason)
            case .accept:
                let screen = replay.toScreen(rev: 0)
                return .updated(CMUXTerminalReadUpdate(
                    screen: screen,
                    sourceMode: .renderGrid,
                    replayIdentity: identity
                ))
            }
        }
    }

    /// Releases replay continuity retained for a surface after its last consumer leaves.
    ///
    /// - Parameters:
    ///   - workspaceId: Workspace containing the released surface.
    ///   - surfaceId: Surface whose replay identity should be forgotten.
    public func releaseTerminalSource(workspaceId: String, surfaceId: String) {
        terminalContinuityState.release(key: CMUXTerminalContinuityState.key(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        ))
    }

    /// Resets all retained terminal replay identities while preserving capability negotiation.
    public func resetTerminalSources() {
        terminalContinuityState.reset()
    }

    /// Resolves and caches one capability-selected terminal source mode per client lifetime.
    func terminalSourceMode() async throws -> CMUXTerminalSourceMode {
        if let negotiatedTerminalSourceMode {
            return negotiatedTerminalSourceMode
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                terminalCapabilityNegotiationWaiters[waiterID] = continuation
                if terminalCapabilityNegotiationTask == nil {
                    terminalCapabilityNegotiationTask = Task { [weak self] in
                        await self?.performTerminalCapabilityNegotiation()
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelTerminalCapabilityNegotiationWaiter(waiterID) }
        }
    }

    /// Performs the sole capability RPC and broadcasts its result to registered waiters.
    func performTerminalCapabilityNegotiation() async {
        do {
            let advertised = try await capabilities()
            let sourceMode: CMUXTerminalSourceMode = advertised.supportsVerifiedTerminalReplay
                ? .renderGrid
                : .legacyText
            completeTerminalCapabilityNegotiation(with: .success(sourceMode))
        } catch {
            completeTerminalCapabilityNegotiation(with: .failure(error))
        }
    }

    func completeTerminalCapabilityNegotiation(
        with result: Result<CMUXTerminalSourceMode, Error>
    ) {
        terminalCapabilityNegotiationTask = nil
        let waiters = Array(terminalCapabilityNegotiationWaiters.values)
        terminalCapabilityNegotiationWaiters.removeAll(keepingCapacity: false)
        if case .success(let sourceMode) = result {
            negotiatedTerminalSourceMode = sourceMode
        }
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    func cancelTerminalCapabilityNegotiationWaiter(_ id: UUID) {
        terminalCapabilityNegotiationWaiters.removeValue(forKey: id)?.resume(
            throwing: CancellationError()
        )
    }

    /// Dispatches one authoritative viewport replay through the ordinary RPC channel.
    func terminalReplay(surfaceId: String) async throws -> CMUXTerminalReplayRaw {
        let response = try await call(
            method: "terminal.replay",
            params: .object([
                "surface_id": .string(surfaceId),
                "anchor": .string("viewport"),
            ])
        )
        let result = try response.unwrapResult()
        do {
            return try result.decode(CMUXTerminalReplayRaw.self)
        } catch {
            throw CMUXTerminalSourceError.malformedReplay(String(describing: error))
        }
    }

    public func notificationCreate(workspaceId: String, surfaceId: String?, title: String,
                                   subtitle: String?, body: String) async throws
    {
        var params: [String: JSONValue] = [
            "workspace_id": .string(workspaceId),
            "title": .string(title),
            "body": .string(body),
        ]
        if let s = surfaceId { params["surface_id"] = .string(s) }
        if let s = subtitle  { params["subtitle"]  = .string(s) }
        _ = try await call(method: "notification.create", params: .object(params)).requireOk()
    }
}

extension RPCResponse {
    public func requireOk() throws -> RPCResponse {
        if let e = error { throw CMUXClientError.rpc(e) }
        return self
    }

    public func unwrapResult() throws -> JSONValue {
        if let e = error { throw CMUXClientError.rpc(e) }
        guard let r = result else {
            throw CMUXClientError.decoding("ok=true but result is nil for id=\(id)")
        }
        return r
    }
}

extension JSONValue {
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try SharedKitJSON.deterministicEncoder.encode(self)
        return try SharedKitJSON.snakeCaseDecoder.decode(T.self, from: data)
    }
}
