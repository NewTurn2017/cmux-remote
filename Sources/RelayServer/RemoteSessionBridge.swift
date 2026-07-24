import Foundation
import RelayCore
import SharedKit

/// Adapts multiplexed broker sessions back into the same protocol machine and
/// Session objects used by direct WebSocket connections.
public actor RemoteSessionBridge {
    public typealias EnvelopeSender = @Sendable (BrokerEnvelope) async -> Void

    private struct RemoteSession {
        let deviceId: String
        let machine: WSProtocolMachine
        var session: Session?
        var helloTimeout: Task<Void, Never>?
    }

    private let sessionManager: SessionManager
    private let cmux: CMUXFacade
    private let history: SurfaceHistoryService
    private let sendEnvelope: EnvelopeSender
    private var sessions: [String: RemoteSession] = [:]

    public init(
        sessionManager: SessionManager,
        cmux: CMUXFacade,
        history: SurfaceHistoryService? = nil,
        sendEnvelope: @escaping EnvelopeSender
    ) {
        self.sessionManager = sessionManager
        self.cmux = cmux
        self.history = history ?? SurfaceHistoryService(cmux: cmux)
        self.sendEnvelope = sendEnvelope
    }

    public var activeSessionCount: Int { sessions.count }

    public func receive(_ envelope: BrokerEnvelope) async {
        switch envelope.type {
        case .sessionOpen:
            guard let deviceId = envelope.deviceId, !deviceId.isEmpty else { return }
            await removeSession(id: envelope.sessionId)
            let sessionId = envelope.sessionId
            let helloTimeout = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
                await self?.helloTimedOut(sessionId: sessionId)
            }
            sessions[envelope.sessionId] = RemoteSession(
                deviceId: deviceId,
                machine: WSProtocolMachine(cmux: cmux),
                session: nil,
                helloTimeout: helloTimeout
            )

        case .sessionText:
            guard let text = envelope.text,
                  let remote = sessions[envelope.sessionId]
            else { return }
            let actions = await remote.machine.processText(text)
            await apply(actions, to: envelope.sessionId)

        case .sessionClose:
            await removeSession(id: envelope.sessionId)
        }
    }

    public func disconnectAll() async {
        let ids = Array(sessions.keys)
        for id in ids { await removeSession(id: id) }
    }

    private func apply(_ actions: [WSProtocolMachine.Action], to sessionId: String) async {
        for action in actions {
            switch action {
            case .sendText(let text):
                await sendEnvelope(.text(sessionId: sessionId, text: text))

            case .close:
                await sendEnvelope(.close(sessionId: sessionId))
                await removeSession(id: sessionId)

            case .attachSession:
                guard var remote = sessions[sessionId] else { continue }
                remote.helloTimeout?.cancel()
                remote.helloTimeout = nil
                if let oldSession = remote.session {
                    await sessionManager.detach(session: oldSession)
                }
                let sender = sendEnvelope
                let attached = await sessionManager.attach(deviceId: remote.deviceId) { frame in
                    guard let data = try? JSONEncoder().encode(frame),
                          let text = String(data: data, encoding: .utf8)
                    else { return }
                    Task { await sender(.text(sessionId: sessionId, text: text)) }
                }
                remote.session = attached
                sessions[sessionId] = remote

            case .subscribe(let responseId, let workspaceId, let surfaceId, let lines):
                guard let session = sessions[sessionId]?.session else {
                    await sendError(
                        responseId: responseId,
                        code: "session_not_attached",
                        message: "hello required before subscribe",
                        sessionId: sessionId
                    )
                    continue
                }
                await session.subscribe(
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    lines: lines
                )
                Task { await history.prewarm(workspaceId: workspaceId, surfaceId: surfaceId) }
                await sendOK(responseId: responseId, sessionId: sessionId)

            case .unsubscribe(let responseId, let surfaceId):
                guard let session = sessions[sessionId]?.session else {
                    await sendError(
                        responseId: responseId,
                        code: "session_not_attached",
                        message: "hello required before unsubscribe",
                        sessionId: sessionId
                    )
                    continue
                }
                await session.unsubscribe(surfaceId: surfaceId)
                await sendOK(responseId: responseId, sessionId: sessionId)

            case .history(let responseId, let workspaceId, let surfaceId, let cursor, let tailLines, let limit):
                do {
                    let result = try await history.page(
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        cursor: cursor,
                        tailLines: tailLines,
                        limit: limit
                    )
                    let response = RPCResponse(id: responseId, ok: true, result: result)
                    await sendEnvelope(.text(
                        sessionId: sessionId,
                        text: WSProtocolMachine.encodeForHandler(response)
                    ))
                } catch {
                    await sendError(
                        responseId: responseId,
                        code: "history_unavailable",
                        message: String(describing: error),
                        sessionId: sessionId
                    )
                }
            }
        }
    }

    private func sendOK(responseId: String, sessionId: String) async {
        let response = RPCResponse(id: responseId, ok: true, result: .object([:]))
        await sendEnvelope(.text(
            sessionId: sessionId,
            text: WSProtocolMachine.encodeForHandler(response)
        ))
    }

    private func sendError(
        responseId: String,
        code: String,
        message: String,
        sessionId: String
    ) async {
        let response = RPCResponse(
            id: responseId,
            ok: false,
            result: nil,
            error: RPCError(code: code, message: message)
        )
        await sendEnvelope(.text(
            sessionId: sessionId,
            text: WSProtocolMachine.encodeForHandler(response)
        ))
    }

    private func removeSession(id: String) async {
        guard let remote = sessions.removeValue(forKey: id) else { return }
        remote.helloTimeout?.cancel()
        if let session = remote.session {
            await sessionManager.detach(session: session)
        }
    }

    private func helloTimedOut(sessionId: String) async {
        guard let remote = sessions[sessionId] else { return }
        let actions = await remote.machine.helloMissed()
        await apply(actions, to: sessionId)
    }
}
