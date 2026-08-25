import Foundation
import NIOCore
import NIOWebSocket
@_spi(RelayServer) import RelayCore
import SharedKit
import Logging

// MARK: - CMUX dispatch facade

/// Indirection so the WS handler can be wired against either the real
/// `CMUXClient` (M3.11) or a recording / throwing test double. The facade
/// owns "one round-trip RPC against the cmux daemon" — fan-out for events
/// is handled by EventStream + SessionManager.broadcastToAll.
public protocol CMUXFacade: Sendable {
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue
}

// MARK: - Pure protocol machine

/// Pure WS protocol logic — Hello detection + RPC dispatch — separated
/// from the NIO channel so it can be unit-tested without an event loop.
/// The handler below applies the actions back onto the channel.
///
/// Plan task 10's tests used `EmbeddedChannel`, but the channel-bound
/// pattern hits the same `Task` drain deadlock we resolved for the
/// CMUXClient baseline tests. Splitting protocol-from-pipeline keeps
/// the unit suite fast and deterministic; the NIO glue is exercised
/// in M3.11's HTTPServer fixture and the M3.13 live smoke.
public actor WSProtocolMachine {
    public enum Action: Equatable, Sendable {
        case sendText(String)
        case close
        case attachSession(deviceId: String)
        case subscribe(responseId: String, workspaceId: String, surfaceId: String, lines: Int)
        case unsubscribe(responseId: String, surfaceId: String)
        /// Requests a hub-backed `screen.full` without another terminal source read.
        case requestFull(responseId: String, surfaceId: String)
        case noteUserInput(surfaceId: String)
    }

    private let cmux: CMUXFacade
    private var helloed = false

    public init(cmux: CMUXFacade) { self.cmux = cmux }

    public var hasHelloed: Bool { helloed }

    /// Drive the machine with one inbound text frame. Returns the actions
    /// the handler should apply to the channel (in order).
    public func processText(_ text: String) async -> [Action] {
        let data = Data(text.utf8)
        if !helloed {
            guard let hello = try? JSONDecoder().decode(HelloFrame.self, from: data) else {
                return [.close]
            }
            helloed = true
            return [.attachSession(deviceId: hello.deviceId)]
        }

        guard let req = try? JSONDecoder().decode(RPCRequest.self, from: data) else {
            return []
        }
        if let immediate = Self.relayOwnedResponse(for: req) {
            return [.sendText(immediate)]
        }
        if let relayAction = Self.relayOwnedAction(for: req) {
            return [relayAction]
        }

        do {
            let result = try await cmux.dispatch(method: req.method, params: req.params)
            let resp = RPCResponse(id: req.id, ok: true, result: result, error: nil)
            var actions: [Action] = [.sendText(Self.encode(resp))]
            if Self.isSuccessfulInput(req),
               case .object(let params) = req.params,
               case .string(let surfaceId)? = params["surface_id"]
            {
                actions.append(.noteUserInput(surfaceId: surfaceId))
            }
            return actions
        } catch {
            let err = RPCError(code: "internal_error",
                               message: String(describing: error))
            let resp = RPCResponse(id: req.id, ok: false, result: nil, error: err)
            return [.sendText(Self.encode(resp))]
        }
    }

    /// The 100ms hello timer fired. Returns `[.close]` if the peer never
    /// sent a hello, `[]` otherwise (handler will see nil and no-op).
    public func helloMissed() -> [Action] {
        helloed ? [] : [.close]
    }


    private static func relayOwnedResponse(for req: RPCRequest) -> String? {
        switch req.method {
        case "host.battery":
            return encode(RPCResponse(id: req.id, ok: true, result: HostBatteryService.snapshot().json, error: nil))
        case "file.upload":
            do {
                let uploaded = try RelayFileUploadService.save(params: req.params)
                return encode(RPCResponse(id: req.id, ok: true, result: uploaded.json, error: nil))
            } catch {
                return encode(errorResponse(id: req.id, code: "upload_failed", message: String(describing: error)))
            }
        default:
            return nil
        }
    }

    private static func relayOwnedAction(for req: RPCRequest) -> Action? {
        guard case .object(let params) = req.params else { return nil }
        switch req.method {
        case "surface.subscribe":
            guard case .string(let workspaceId)? = params["workspace_id"],
                  case .string(let surfaceId)? = params["surface_id"]
            else {
                return .sendText(Self.encode(errorResponse(id: req.id, code: "invalid_params",
                                                           message: "surface.subscribe requires workspace_id and surface_id")))
            }
            let lines: Int
            if case .int(let value)? = params["lines"] { lines = max(1, Int(value)) }
            else { lines = 200 }
            return .subscribe(responseId: req.id, workspaceId: workspaceId, surfaceId: surfaceId, lines: lines)
        case "surface.unsubscribe":
            guard case .string(let surfaceId)? = params["surface_id"] else {
                return .sendText(Self.encode(errorResponse(id: req.id, code: "invalid_params",
                                                           message: "surface.unsubscribe requires surface_id")))
            }
            return .unsubscribe(responseId: req.id, surfaceId: surfaceId)
        case "surface.read_text":
            guard case .string(let surfaceId)? = params["surface_id"] else {
                return .sendText(Self.encode(errorResponse(id: req.id, code: "invalid_params",
                                                           message: "surface.read_text requires surface_id")))
            }
            return .requestFull(responseId: req.id, surfaceId: surfaceId)
        default:
            return nil
        }
    }

    private static func isSuccessfulInput(_ request: RPCRequest) -> Bool {
        request.method == "surface.send_text" || request.method == "surface.send_key"
    }

    private static func okResponse(id: String) -> RPCResponse {
        RPCResponse(id: id, ok: true, result: .object([:]), error: nil)
    }

    private static func errorResponse(id: String, code: String, message: String) -> RPCResponse {
        RPCResponse(id: id, ok: false, result: nil, error: RPCError(code: code, message: message))
    }

    public static func encodeForHandler(_ resp: RPCResponse) -> String {
        encode(resp)
    }

    private static func encode(_ resp: RPCResponse) -> String {
        guard let data = try? SharedKitJSON.deterministicEncoder.encode(resp),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - NIO channel handler

private actor WSActionQueue {
    private var tail: Task<Void, Never>?

    func run(_ operation: @escaping @Sendable () async -> Void) {
        let previous = tail
        let next = Task {
            await previous?.value
            await operation()
        }
        tail = next
    }
}

private final class WSChannelContext: @unchecked Sendable {
    private weak var context: ChannelHandlerContext?
    private let eventLoop: any EventLoop

    init(_ context: ChannelHandlerContext) {
        self.context = context
        self.eventLoop = context.eventLoop
    }

    func execute(_ operation: @escaping @Sendable (ChannelHandlerContext) -> Void) {
        eventLoop.execute { [self] in
            guard let context else { return }
            operation(context)
        }
    }

    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (ChannelHandlerContext) -> Value
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            eventLoop.execute { [self] in
                guard let context else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: operation(context))
            }
        }
    }
}

/// Thin NIO `ChannelInboundHandler` that drives `WSProtocolMachine` and
/// applies its actions on the channel's event loop. Hello timeout is a
/// 100ms `eventLoop.scheduleTask`; on hello the machine emits an
/// `attachSession` action that we map to `SessionManager.attach`,
/// installing a `sendFrame` closure that hops back onto the loop to
/// write the WS text frame.
///
/// `@unchecked Sendable`: all mutable state (`helloTimer`, `session`) is
/// touched only inside `eventLoop.execute { ... }` blocks; the async
/// Task bodies treat the handler as a Sendable reference but never read
/// or write its mutable fields directly.
public final class WebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = WebSocketFrame
    public typealias OutboundOut = WebSocketFrame

    /// Default per-connection bound for WebSocket frames waiting behind a write.
    public static let defaultMaximumQueuedOutputBytes = 2 * 1024 * 1024

    public let deviceId: String
    private let deviceStore: DeviceStore
    private let sessionManager: any WebSocketSessionManaging
    private let machine: WSProtocolMachine
    private let actionQueue = WSActionQueue()
    private let logger = Logger(label: "cmux-relay.ws")

    private var helloTimer: Scheduled<Void>?
    private var channelContext: WSChannelContext?
    private var sessionLifecycle: WebSocketSessionLifecycle?
    private var channelGeneration: UInt64 = 0
    private var outputPump: WebSocketOutputPump?
    private let maximumQueuedOutputBytes: Int

    /// Creates a WebSocket handler with a bounded, writability-aware output queue.
    ///
    /// - Parameters:
    ///   - deviceId: Authenticated device identifier for this connection.
    ///   - deviceStore: Registered-device persistence used by relay services.
    ///   - sessionManager: Session composition and render-hub owner.
    ///   - cmuxClient: Facade for non-relay-owned RPC methods.
    ///   - maximumQueuedOutputBytes: Hard queued-byte cap before terminal coalescing or close.
    public init(deviceId: String,
                deviceStore: DeviceStore,
                sessionManager: SessionManager,
                cmuxClient: CMUXFacade,
                maximumQueuedOutputBytes: Int = WebSocketHandler.defaultMaximumQueuedOutputBytes)
    {
        self.deviceId = deviceId
        self.deviceStore = deviceStore
        self.sessionManager = sessionManager
        self.machine = WSProtocolMachine(cmux: cmuxClient)
        self.maximumQueuedOutputBytes = maximumQueuedOutputBytes
    }

    init(
        deviceId: String,
        deviceStore: DeviceStore,
        sessionLifecycleManager: any WebSocketSessionManaging,
        cmuxClient: CMUXFacade,
        maximumQueuedOutputBytes: Int = WebSocketHandler.defaultMaximumQueuedOutputBytes
    ) {
        self.deviceId = deviceId
        self.deviceStore = deviceStore
        self.sessionManager = sessionLifecycleManager
        self.machine = WSProtocolMachine(cmux: cmuxClient)
        self.maximumQueuedOutputBytes = maximumQueuedOutputBytes
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        channelContext = WSChannelContext(context)
        sessionLifecycle = WebSocketSessionLifecycle(
            eventLoop: context.eventLoop,
            manager: sessionManager
        )
        installOutputPump(context: context)
        if context.channel.isActive {
            activateChannel(context: context)
        }
    }

    public func channelActive(context: ChannelHandlerContext) {
        activateChannel(context: context)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .text else { return }
        let buf = frame.unmaskedData
        guard let text = buf.getString(at: buf.readerIndex,
                                       length: buf.readableBytes) else { return }

        let channel = channelContext ?? WSChannelContext(context)
        channelContext = channel
        let generation = channelGeneration
        Task { [weak self] in
            guard let self else { return }
            await self.actionQueue.run {
                let actions = await self.machine.processText(text)
                await self.apply(
                    actions: actions,
                    generation: generation,
                    on: channel
                )
            }
        }
    }

    public func channelInactive(context: ChannelHandlerContext) {
        invalidateChannel(context: context, closeChannel: false)
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        invalidateChannel(context: context, closeChannel: true)
        sessionLifecycle = nil
    }

    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        outputPump?.writabilityChanged()
        context.fireChannelWritabilityChanged()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.warning("WebSocket channel failed: \(String(describing: error))")
        invalidateChannel(context: context, closeChannel: true)
    }

    /// Async-side action applier — used after `processText`. Dispatches
    /// each action; for `attachSession`, the heavy work (calling
    /// SessionManager) happens on the actor, then the resulting Session
    /// is stored under the event loop.
    private func apply(
        actions: [WSProtocolMachine.Action],
        generation: UInt64,
        on channel: WSChannelContext
    ) async {
        for action in actions {
            switch action {
            case .sendText(let text):
                channel.execute { _ in
                    self.enqueueCritical(text, generation: generation)
                }

            case .close:
                channel.execute { context in
                    guard self.sessionLifecycle?.isCurrent(generation) == true else { return }
                    self.invalidateChannel(context: context, closeChannel: true)
                }

            case .attachSession:
                let lifecycle = await channel.perform { _ -> WebSocketSessionLifecycle? in
                    guard self.sessionLifecycle?.isCurrent(generation) == true else { return nil }
                    self.helloTimer?.cancel()
                    self.helloTimer = nil
                    return self.sessionLifecycle
                } ?? nil
                guard let lifecycle else { continue }
                do {
                    _ = try await lifecycle.attach(
                        deviceId: deviceId,
                        generation: generation,
                        sendOutputEvent: { [weak self, weak channel] event in
                            guard let handler = self, let channel else { return }
                            channel.execute { _ in
                                handler.enqueue(event, generation: generation)
                            }
                        }
                    )
                } catch {
                    channel.execute { context in
                        guard self.sessionLifecycle?.isCurrent(generation) == true else { return }
                        self.logger.warning("WebSocket session attach failed: \(String(describing: error))")
                        self.invalidateChannel(context: context, closeChannel: true)
                    }
                }

            case .subscribe(let responseId, let workspaceId, let surfaceId, let lines):
                guard let session = await currentSession(generation: generation, on: channel) else {
                    enqueueSessionRequired(
                        responseId: responseId,
                        message: "hello required before subscribe",
                        generation: generation,
                        on: channel
                    )
                    continue
                }
                do {
                    try await session.subscribe(
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        lines: lines
                    )
                    enqueueResponse(
                        RPCResponse(id: responseId, ok: true, result: .object([:])),
                        generation: generation,
                        on: channel
                    )
                } catch {
                    enqueueResponse(
                        RPCResponse(
                            id: responseId,
                            ok: false,
                            result: nil,
                            error: RPCError(
                                code: "subscription_rejected",
                                message: String(describing: error)
                            )
                        ),
                        generation: generation,
                        on: channel
                    )
                }

            case .unsubscribe(let responseId, let surfaceId):
                guard let session = await currentSession(generation: generation, on: channel) else {
                    enqueueSessionRequired(
                        responseId: responseId,
                        message: "hello required before unsubscribe",
                        generation: generation,
                        on: channel
                    )
                    continue
                }
                await session.unsubscribe(surfaceId: surfaceId)
                enqueueResponse(
                    RPCResponse(id: responseId, ok: true, result: .object([:])),
                    generation: generation,
                    on: channel
                )

            case .requestFull(let responseId, let surfaceId):
                guard let session = await currentSession(generation: generation, on: channel) else {
                    enqueueSessionRequired(
                        responseId: responseId,
                        message: "hello required before full recovery",
                        generation: generation,
                        on: channel
                    )
                    continue
                }
                let sent = await session.sendAuthoritativeFull(surfaceId: surfaceId)
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
                enqueueResponse(response, generation: generation, on: channel)

            case .noteUserInput(let surfaceId):
                await currentSession(generation: generation, on: channel)?
                    .noteUserInput(surfaceId: surfaceId)
            }
        }
    }

    /// Sync-side action applier used by the hello deadline on the channel event loop.
    private func apply(
        actions: [WSProtocolMachine.Action],
        generation: UInt64,
        on context: ChannelHandlerContext
    ) {
        guard sessionLifecycle?.isCurrent(generation) == true else { return }
        for action in actions {
            switch action {
            case .sendText(let text): enqueueCritical(text, generation: generation)
            case .close:              invalidateChannel(context: context, closeChannel: true)
            case .attachSession:      break
            case .subscribe, .unsubscribe, .requestFull, .noteUserInput: break
            }
        }
    }

    private func currentSession(
        generation: UInt64,
        on channel: WSChannelContext
    ) async -> Session? {
        await channel.perform { _ in
            self.sessionLifecycle?.currentSession(generation: generation)
        } ?? nil
    }

    private func enqueueSessionRequired(
        responseId: String,
        message: String,
        generation: UInt64,
        on channel: WSChannelContext
    ) {
        enqueueResponse(
            RPCResponse(
                id: responseId,
                ok: false,
                result: nil,
                error: RPCError(code: "session_not_attached", message: message)
            ),
            generation: generation,
            on: channel
        )
    }

    private func enqueueResponse(
        _ response: RPCResponse,
        generation: UInt64,
        on channel: WSChannelContext
    ) {
        let text = WSProtocolMachine.encodeForHandler(response)
        channel.execute { _ in
            self.enqueueCritical(text, generation: generation)
        }
    }

    private func enqueueCritical(_ text: String, generation: UInt64) {
        guard sessionLifecycle?.isCurrent(generation) == true else { return }
        outputPump?.enqueueCritical(text)
    }

    private func enqueue(_ event: SessionOutboundEvent, generation: UInt64) {
        guard sessionLifecycle?.isCurrent(generation) == true else { return }
        switch event {
        case .frame(let output):
            outputPump?.enqueue(output)
        case .retire(let surfaceId, let streamIdentity):
            outputPump?.retire(
                surfaceId: surfaceId,
                streamIdentity: streamIdentity
            )
        }
    }

    private func activateChannel(context: ChannelHandlerContext) {
        if outputPump == nil {
            installOutputPump(context: context)
        }
        let machine = self.machine
        let channel = channelContext ?? WSChannelContext(context)
        channelContext = channel
        let generation: UInt64
        if sessionLifecycle?.isCurrent(channelGeneration) == true {
            generation = channelGeneration
        } else {
            generation = sessionLifecycle?.activate() ?? 0
            channelGeneration = generation
        }
        helloTimer?.cancel()
        helloTimer = context.eventLoop.scheduleTask(in: .milliseconds(100)) { [weak self] in
            guard let self else { return }
            Task {
                let actions = await machine.helloMissed()
                channel.execute {
                    self.apply(actions: actions, generation: generation, on: $0)
                }
            }
        }
    }

    private func installOutputPump(context: ChannelHandlerContext) {
        outputPump = WebSocketOutputPump(
            channel: NIOWebSocketOutputChannel(context: context),
            maximumQueuedBytes: maximumQueuedOutputBytes
        )
    }

    private func invalidateChannel(
        context: ChannelHandlerContext,
        closeChannel: Bool
    ) {
        helloTimer?.cancel()
        helloTimer = nil
        if let session = sessionLifecycle?.invalidate() {
            let manager = sessionManager
            Task { await manager.detach(session: session) }
        }
        if closeChannel {
            outputPump?.close()
        } else {
            outputPump?.channelClosed()
        }
        outputPump = nil
        channelContext = nil
    }
}
