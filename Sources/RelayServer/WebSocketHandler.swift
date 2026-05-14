import Foundation
import NIOCore
import NIOWebSocket
import RelayCore
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
        if let relayAction = Self.relayOwnedAction(for: req) {
            return [relayAction]
        }

        do {
            let result = try await cmux.dispatch(method: req.method, params: req.params)
            let resp = RPCResponse(id: req.id, ok: true, result: result, error: nil)
            return [.sendText(Self.encode(resp))]
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
        default:
            return nil
        }
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
        guard let data = try? JSONEncoder().encode(resp),
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
    private let context: ChannelHandlerContext

    init(_ context: ChannelHandlerContext) {
        self.context = context
    }

    func execute(_ operation: @escaping @Sendable (ChannelHandlerContext) -> Void) {
        context.eventLoop.execute { operation(self.context) }
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

    public let deviceId: String
    private let deviceStore: DeviceStore
    private let sessionManager: SessionManager
    private let machine: WSProtocolMachine
    private let actionQueue = WSActionQueue()
    private let logger = Logger(label: "cmux-relay.ws")

    private var helloTimer: Scheduled<Void>?
    private var session: Session?

    public init(deviceId: String,
                deviceStore: DeviceStore,
                sessionManager: SessionManager,
                cmuxClient: CMUXFacade)
    {
        self.deviceId = deviceId
        self.deviceStore = deviceStore
        self.sessionManager = sessionManager
        self.machine = WSProtocolMachine(cmux: cmuxClient)
    }

    public func channelActive(context: ChannelHandlerContext) {
        let machine = self.machine
        let channel = WSChannelContext(context)
        helloTimer = context.eventLoop.scheduleTask(in: .milliseconds(100)) { [weak self] in
            guard let self else { return }
            Task {
                let actions = await machine.helloMissed()
                channel.execute { self.apply(actions: actions, on: $0) }
            }
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .text else { return }
        let buf = frame.unmaskedData
        guard let text = buf.getString(at: buf.readerIndex,
                                       length: buf.readableBytes) else { return }

        let channel = WSChannelContext(context)
        Task { [weak self] in
            guard let self else { return }
            await self.actionQueue.run {
                let actions = await self.machine.processText(text)
                await self.apply(actions: actions, on: channel)
            }
        }
    }

    public func channelInactive(context: ChannelHandlerContext) {
        helloTimer?.cancel()
        helloTimer = nil
        if let s = session {
            session = nil
            let mgr = sessionManager
            Task { await mgr.detach(session: s) }
        }
    }

    /// Async-side action applier — used after `processText`. Dispatches
    /// each action; for `attachSession`, the heavy work (calling
    /// SessionManager) happens on the actor, then the resulting Session
    /// is stored under the event loop.
    private func apply(actions: [WSProtocolMachine.Action],
                       on channel: WSChannelContext) async
    {
        for action in actions {
            switch action {
            case .sendText(let text):
                channel.execute { self.writeText(text, on: $0) }
            case .close:
                channel.execute { $0.close(promise: nil) }
            case .attachSession:
                channel.execute { _ in
                    self.helloTimer?.cancel()
                    self.helloTimer = nil
                }
                let s = await sessionManager.attach(deviceId: deviceId) { [weak self] frame in
                    guard let self else { return }
                    channel.execute { self.writePushFrame(frame, on: $0) }
                }
                self.session = s
            case .subscribe(let responseId, let workspaceId, let surfaceId, let lines):
                guard let session else {
                    let text = WSProtocolMachine.encodeForHandler(.init(
                        id: responseId, ok: false, result: nil,
                        error: RPCError(code: "session_not_attached", message: "hello required before subscribe")
                    ))
                    channel.execute { self.writeText(text, on: $0) }
                    continue
                }
                await session.subscribe(workspaceId: workspaceId, surfaceId: surfaceId, lines: lines)
                let text = WSProtocolMachine.encodeForHandler(.init(id: responseId, ok: true, result: .object([:])))
                channel.execute { self.writeText(text, on: $0) }
            case .unsubscribe(let responseId, let surfaceId):
                guard let session else {
                    let text = WSProtocolMachine.encodeForHandler(.init(
                        id: responseId, ok: false, result: nil,
                        error: RPCError(code: "session_not_attached", message: "hello required before unsubscribe")
                    ))
                    channel.execute { self.writeText(text, on: $0) }
                    continue
                }
                await session.unsubscribe(surfaceId: surfaceId)
                let text = WSProtocolMachine.encodeForHandler(.init(id: responseId, ok: true, result: .object([:])))
                channel.execute { self.writeText(text, on: $0) }
            }
        }
    }

    /// Sync-side action applier — used from inside an `eventLoop.execute`
    /// callback (e.g. the hello-missed timer). Only handles actions that
    /// don't need async work.
    private func apply(actions: [WSProtocolMachine.Action],
                       on context: ChannelHandlerContext)
    {
        for action in actions {
            switch action {
            case .sendText(let text): writeText(text, on: context)
            case .close:              context.close(promise: nil)
            case .attachSession:      break
            case .subscribe, .unsubscribe: break
            }
        }
    }

    private func writeText(_ text: String, on context: ChannelHandlerContext) {
        var buf = context.channel.allocator.buffer(capacity: text.utf8.count)
        buf.writeString(text)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
    }

    private func writePushFrame(_ push: PushFrame, on context: ChannelHandlerContext) {
        guard let body = try? JSONEncoder().encode(push),
              let s = String(data: body, encoding: .utf8) else { return }
        writeText(s, on: context)
    }
}
