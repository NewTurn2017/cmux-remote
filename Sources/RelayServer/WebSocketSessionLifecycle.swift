import NIOCore
@_spi(RelayServer) import RelayCore
import SharedKit

/// Owns one WebSocket connection's generation, hello deadline, and installed
/// session. Every mutable field is accessed only on `eventLoop`.
final class WebSocketSessionLifecycle: @unchecked Sendable {
    private enum AttachmentState {
        case none
        case attaching(generation: UInt64)
        case attached(generation: UInt64, session: Session)
    }

    private let eventLoop: any EventLoop
    private let channel: WSChannelContext
    private let manager: any WebSocketSessionManaging
    private let deviceId: String

    private var generation: UInt64 = 0
    private var active = false
    private var helloTimer: Scheduled<Void>?
    private var attachmentState: AttachmentState = .none

    init(
        eventLoop: any EventLoop,
        channel: WSChannelContext,
        manager: any WebSocketSessionManaging,
        deviceId: String
    ) {
        self.eventLoop = eventLoop
        self.channel = channel
        self.manager = manager
        self.deviceId = deviceId
    }

    var activeGeneration: UInt64? {
        precondition(eventLoop.inEventLoop)
        return active ? generation : nil
    }

    @discardableResult
    func activate(machine: WSProtocolMachine, queue: WSActionQueue) -> UInt64 {
        precondition(eventLoop.inEventLoop)
        if active { return generation }
        generation &+= 1
        active = true
        attachmentState = .none
        let candidate = generation
        helloTimer?.cancel()
        helloTimer = eventLoop.scheduleTask(in: .milliseconds(100)) { [weak self, weak queue] in
            guard let queue else { return }
            queue.enqueue { [weak self] in
                let actions = await machine.helloMissed()
                guard !Task.isCancelled else { return }
                await self?.apply(actions: actions, generation: candidate)
            }
        }
        return candidate
    }

    func invalidate(closeChannel: Bool = false) {
        precondition(eventLoop.inEventLoop)
        guard active || helloTimer != nil || installedSession != nil else {
            channel.detach(closeChannel: closeChannel)
            return
        }
        generation &+= 1
        active = false
        helloTimer?.cancel()
        helloTimer = nil
        let session = installedSession
        attachmentState = .none
        channel.detach(closeChannel: closeChannel)
        if let session {
            let manager = self.manager
            Task {
                await manager.detach(session: session)
            }
        }
    }

    func writabilityChanged() {
        precondition(eventLoop.inEventLoop)
        channel.writabilityChanged()
    }

    func apply(
        actions: [WSProtocolMachine.Action],
        generation candidate: UInt64
    ) async {
        for action in actions {
            switch action {
            case .sendText(let text):
                writeText(text, generation: candidate)

            case .close:
                close(generation: candidate)

            case .attachSession:
                guard await beginAttachment(generation: candidate) else { continue }
                do {
                    let session = try await manager.attachForBoundedOutputEvents(
                        deviceId: deviceId
                    ) { [weak self] event in
                        self?.writeOutputEvent(event, generation: candidate)
                    }
                    let installed = await install(session: session, generation: candidate)
                    if !installed {
                        await manager.detach(session: session)
                    }
                } catch {
                    guard !Task.isCancelled else { continue }
                    close(generation: candidate)
                }

            case .subscribe(let responseId, let workspaceId, let surfaceId, let lines):
                guard !Task.isCancelled,
                      let session = await currentSession(generation: candidate),
                      !Task.isCancelled
                else {
                    if !Task.isCancelled {
                        writeSessionRequired(
                            responseId: responseId,
                            message: "hello required before subscribe",
                            generation: candidate
                        )
                    }
                    continue
                }
                do {
                    try await session.subscribe(
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        lines: lines
                    )
                    guard !Task.isCancelled else { continue }
                    writeResponse(
                        RPCResponse(id: responseId, ok: true, result: .object([:])),
                        generation: candidate
                    )
                } catch {
                    guard !Task.isCancelled else { continue }
                    writeResponse(
                        RPCResponse(
                            id: responseId,
                            ok: false,
                            result: nil,
                            error: RPCError(
                                code: "surface_subscription_failed",
                                message: String(describing: error)
                            )
                        ),
                        generation: candidate
                    )
                }

            case .unsubscribe(let responseId, let surfaceId):
                guard !Task.isCancelled,
                      let session = await currentSession(generation: candidate),
                      !Task.isCancelled
                else {
                    if !Task.isCancelled {
                        writeSessionRequired(
                            responseId: responseId,
                            message: "hello required before unsubscribe",
                            generation: candidate
                        )
                    }
                    continue
                }
                await session.unsubscribe(surfaceId: surfaceId)
                guard !Task.isCancelled else { continue }
                writeResponse(
                    RPCResponse(id: responseId, ok: true, result: .object([:])),
                    generation: candidate
                )

            case .requestFull(let responseId, let surfaceId):
                guard !Task.isCancelled,
                      let session = await currentSession(generation: candidate),
                      !Task.isCancelled
                else {
                    if !Task.isCancelled {
                        writeSessionRequired(
                            responseId: responseId,
                            message: "hello required before full recovery",
                            generation: candidate
                        )
                    }
                    continue
                }
                let sent = await session.sendAuthoritativeFull(surfaceId: surfaceId)
                guard !Task.isCancelled else { continue }
                let response = sent
                    ? RPCResponse(id: responseId, ok: true, result: .object([:]))
                    : RPCResponse(
                        id: responseId,
                        ok: false,
                        result: nil,
                        error: RPCError(
                            code: "snapshot_unavailable",
                            message: "surface has no active authoritative snapshot"
                        )
                    )
                writeResponse(response, generation: candidate)

            case .noteUserInput(let surfaceId):
                guard !Task.isCancelled,
                      let session = await currentSession(generation: candidate),
                      !Task.isCancelled
                else { continue }
                await session.noteUserInput(surfaceId: surfaceId)
            }
        }
    }

    private var installedSession: Session? {
        precondition(eventLoop.inEventLoop)
        guard case .attached(_, let session) = attachmentState else { return nil }
        return session
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        precondition(eventLoop.inEventLoop)
        return active && generation == candidate
    }

    private func beginAttachment(generation candidate: UInt64) async -> Bool {
        await performOnEventLoop {
            guard self.isCurrent(candidate) else { return false }
            guard case .none = self.attachmentState else { return false }
            self.helloTimer?.cancel()
            self.helloTimer = nil
            self.attachmentState = .attaching(generation: candidate)
            return true
        } ?? false
    }

    private func install(session: Session, generation candidate: UInt64) async -> Bool {
        await performOnEventLoop {
            guard self.isCurrent(candidate) else { return false }
            guard case .attaching(let attachingGeneration) = self.attachmentState,
                  attachingGeneration == candidate
            else { return false }
            self.attachmentState = .attached(generation: candidate, session: session)
            return true
        } ?? false
    }

    private func currentSession(generation candidate: UInt64) async -> Session? {
        await performOnEventLoop {
            guard self.isCurrent(candidate) else { return nil }
            guard case .attached(let attachedGeneration, let session) = self.attachmentState,
                  attachedGeneration == candidate
            else { return nil }
            return session
        } ?? nil
    }

    private func writeSessionRequired(
        responseId: String,
        message: String,
        generation candidate: UInt64
    ) {
        writeResponse(
            RPCResponse(
                id: responseId,
                ok: false,
                result: nil,
                error: RPCError(code: "session_not_attached", message: message)
            ),
            generation: candidate
        )
    }

    private func writeResponse(_ response: RPCResponse, generation candidate: UInt64) {
        writeText(WSProtocolMachine.encodeForHandler(response), generation: candidate)
    }

    private func writeText(_ text: String, generation candidate: UInt64) {
        channel.writeText(text) { [weak self] in
            self?.isCurrent(candidate) == true
        }
    }

    private func writeOutputEvent(_ event: SessionOutboundEvent, generation candidate: UInt64) {
        channel.writeOutputEvent(event) { [weak self] in
            self?.isCurrent(candidate) == true
        }
    }

    private func close(generation candidate: UInt64) {
        channel.close { [weak self] in
            self?.isCurrent(candidate) == true
        }
    }

    private func performOnEventLoop<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value? {
        do {
            return try await eventLoop.submit(operation).get()
        } catch {
            return nil
        }
    }
}
