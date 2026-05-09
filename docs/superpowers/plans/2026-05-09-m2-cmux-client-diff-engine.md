# M2 — CMUXClient + DiffEngine

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the Mac-side library that talks to the running cmux Unix socket (`/tmp/cmux.sock`) and the polling DiffEngine that converts `surface.read_text` snapshots into `DiffOp` streams ready for fanout to phones.

**Architecture:** Two SwiftPM modules — `CMUXClient` (NIO Unix socket + newline-delimited JSON-RPC dispatch) and the diff/hash subsystem inside `RelayCore` (`DiffEngine`, `RowState`, `ScreenHasher`). No networking outside `localhost`. No tsnet, no APNs — those land in M3 and M6. EmbeddedChannel + a fake cmux fixture drive every test.

**Tech Stack:** swift-nio (NIOCore, NIOPosix, NIOFoundationCompat), swift-log, swift-crypto (SHA256 for stable row+screen checksum), swift-testing for DiffEngine, XCTest for CMUXClient (Embedded NIO works cleaner under XCTest).

**Branch:** `m2-cmux-diff` from `main`, after M1 has merged.

---

## Spec coverage

- Spec section 6.3 ("cmux RPC mapping") — every relay-bound method gets a typed wrapper.
- Spec section 6.4 ("DiffEngine") — full polling loop including idle adaptation, fps cap, checksum.
- Spec section 11 ("Test strategy") — `swift-testing + golden fixtures` for DiffEngine, `XCTest + socketpair mock` for CMUXClient.
- Spec section 12.2 ("cmux socket access") — 503 path when socket missing.

## Pre-flight (Task 0)

Before writing any code, verify the framing cmux uses on its Unix socket. The spec assumes newline-delimited JSON-RPC; if cmux actually uses Content-Length headers (LSP-style) or a length-prefixed binary frame, the framer swaps but every other task remains.

- [ ] **Step 1: Confirm cmux is running**

```bash
ls -l /tmp/cmux.sock
```
Expected: socket exists. If not, start cmux first.

- [ ] **Step 2: Send a probe request**

```bash
printf '{"id":1,"method":"workspace.list","params":{}}\n' | nc -U /tmp/cmux.sock | head -1
```
Expected: a single JSON line response. If the response is multi-line / has a `Content-Length: ` header / is binary, record the actual framing in `docs/specs/2026-05-09-cmux-iphone-bridge-design.md` under section 14 ("Open questions") **before** continuing.

- [ ] **Step 3: Branch**

```bash
git checkout main
git checkout -b m2-cmux-diff
```

- [ ] **Step 4: Re-enable downstream targets + add deps in `Package.swift`**

M1.8 trimmed all external package dependencies because they were unused at that point. M2 reintroduces only the deps consumed by `CMUXClient` + `RelayCore`. Add the following to the `dependencies:` array (replacing the MILESTONE-GATED comment block):

```swift
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        // MILESTONE-GATED for M3: swift-nio-ssl, swift-argument-parser, swift-crypto, async-http-client
    ],
```

Then uncomment the four targets gated as `MILESTONE-GATED` in M1, leaving `RelayServer` alone (M3 turns that on); also re-add the `CMUXClient` and `RelayCore` library products. The targets array becomes:

```swift
    targets: [
        .target(name: "SharedKit"),
        .target(
            name: "CMUXClient",
            dependencies: [
                "SharedKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "RelayCore",
            dependencies: [
                "SharedKit",
                "CMUXClient",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(name: "SharedKitTests",  dependencies: ["SharedKit"]),
        .testTarget(name: "CMUXClientTests", dependencies: [
            "CMUXClient",
            .product(name: "NIOEmbedded", package: "swift-nio"),
        ]),
        .testTarget(name: "DiffEngineTests", dependencies: [
            "RelayCore",
            .product(name: "NIOEmbedded", package: "swift-nio"),
        ], resources: [
            .copy("Fixtures"),
        ]),
        // RelayServer + RelayServerTests + RelayCoreTests gated until M3.
    ]
```

Add the products entry too:

```swift
    products: [
        .library(name: "SharedKit",  targets: ["SharedKit"]),
        .library(name: "CMUXClient", targets: ["CMUXClient"]),
        .library(name: "RelayCore",  targets: ["RelayCore"]),
    ],
```

Run `swift build`. Expected: `Build complete!`. (Empty target dirs need the `.gitkeep` placeholder from M1; one real source file in each gets added in this milestone, so the placeholder can be deleted as soon as the first real file lands.)

- [ ] **Step 5: Commit**

```bash
git add Package.swift docs/specs/2026-05-09-cmux-iphone-bridge-design.md
git commit -m "M2.0: re-enable CMUXClient + RelayCore targets; record cmux framing"
```

---

## Task 1 — `UnixSocketChannel` + line framer

**Files:**
- Create: `Sources/CMUXClient/UnixSocketChannel.swift`
- Create: `Sources/CMUXClient/LineFramer.swift`
- Test:   `Tests/CMUXClientTests/LineFramerTests.swift`

(If pre-flight Step 2 revealed length-prefixed framing instead of newline-delimited, rename `LineFramer` to `LengthFramer` and use a `NIOLengthFieldBasedFrameDecoder` from NIOExtras instead — the rest of the milestone is untouched.)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import NIOCore
import NIOEmbedded
@testable import CMUXClient

final class LineFramerTests: XCTestCase {
    func testDecodesSingleLine() throws {
        let chan = EmbeddedChannel(handler: LineFrameDecoder())
        var buf = ByteBufferAllocator().buffer(capacity: 32)
        buf.writeString("{\"x\":1}\n")
        try chan.writeInbound(buf)
        let line: ByteBuffer = try XCTUnwrap(try chan.readInbound())
        XCTAssertEqual(line.getString(at: 0, length: line.readableBytes), "{\"x\":1}")
    }

    func testBuffersAcrossWrites() throws {
        let chan = EmbeddedChannel(handler: LineFrameDecoder())
        var a = ByteBufferAllocator().buffer(capacity: 8); a.writeString("{\"a\"")
        var b = ByteBufferAllocator().buffer(capacity: 8); b.writeString(":1}\n{\"b\":2}\n")
        try chan.writeInbound(a)
        XCTAssertNil(try chan.readInbound() as ByteBuffer?)
        try chan.writeInbound(b)
        let first: ByteBuffer  = try XCTUnwrap(try chan.readInbound())
        let second: ByteBuffer = try XCTUnwrap(try chan.readInbound())
        XCTAssertEqual(first.getString(at: 0, length: first.readableBytes), "{\"a\":1}")
        XCTAssertEqual(second.getString(at: 0, length: second.readableBytes), "{\"b\":2}")
    }

    func testEncoderAppendsNewline() throws {
        let chan = EmbeddedChannel(handler: LineFrameEncoder())
        var buf = ByteBufferAllocator().buffer(capacity: 8); buf.writeString("hi")
        try chan.writeOutbound(buf)
        let out: ByteBuffer = try XCTUnwrap(try chan.readOutbound())
        XCTAssertEqual(out.getString(at: 0, length: out.readableBytes), "hi\n")
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter CMUXClientTests.LineFramerTests`
Expected: FAIL (types missing).

- [ ] **Step 3: Implement framer**

`Sources/CMUXClient/LineFramer.swift`:

```swift
import NIOCore

public final class LineFrameDecoder: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer

    private var buffer = ByteBuffer()

    public init() {}

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = self.unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        while let nl = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) {
            let lineLength = nl - buffer.readerIndex
            if let line = buffer.readSlice(length: lineLength) {
                _ = buffer.readInteger(as: UInt8.self) // discard \n
                context.fireChannelRead(self.wrapInboundOut(line))
            }
        }
        if buffer.readableBytes == 0 { buffer.clear() }
    }
}

public final class LineFrameEncoder: ChannelOutboundHandler {
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    public init() {}

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buf = self.unwrapOutboundIn(data)
        buf.writeInteger(UInt8(ascii: "\n"))
        context.write(self.wrapOutboundOut(buf), promise: promise)
    }
}
```

`Sources/CMUXClient/UnixSocketChannel.swift`:

```swift
import NIOCore
import NIOPosix
import Foundation

public enum UnixSocketChannelError: Error, Equatable {
    case socketMissing(String)
    case connectFailed(String)
}

/// Connects to a Unix-domain socket and installs the JSON line framer.
public struct UnixSocketChannel {
    public let path: String
    public let group: EventLoopGroup
    public init(path: String, group: EventLoopGroup) { self.path = path; self.group = group }

    public func connect(handler: @escaping @Sendable (Channel) -> EventLoopFuture<Void>)
        async throws -> Channel
    {
        guard FileManager.default.fileExists(atPath: path) else {
            throw UnixSocketChannelError.socketMissing(path)
        }
        let bs = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    LineFrameDecoder(),
                    LineFrameEncoder(),
                ]).flatMap { handler(channel) }
            }
        do {
            return try await bs.connect(unixDomainSocketPath: path).get()
        } catch {
            throw UnixSocketChannelError.connectFailed(String(describing: error))
        }
    }
}
```

- [ ] **Step 4: Run — expect green**

Run: `swift test --filter CMUXClientTests.LineFramerTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
rm -f Sources/CMUXClient/.gitkeep
git add Sources/CMUXClient/UnixSocketChannel.swift Sources/CMUXClient/LineFramer.swift Tests/CMUXClientTests/LineFramerTests.swift
git commit -m "M2.1: Unix-socket channel + newline framer"
```

---

## Task 2 — `CMUXClient` request/response correlation

The high-level client multiplexes outbound requests by id and awaits responses with timeouts. It is `Actor`-isolated because the dispatch table is mutated from both writer (outbound) and reader (inbound) sides.

**Files:**
- Create: `Sources/CMUXClient/CMUXClient.swift`
- Test:   `Tests/CMUXClientTests/CMUXClientTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import NIOCore
import NIOEmbedded
import SharedKit
@testable import CMUXClient

final class CMUXClientTests: XCTestCase {
    /// EmbeddedChannel-backed harness so tests don't open real Unix sockets.
    private func makeHarness() -> (EmbeddedChannel, CMUXClient) {
        let chan = EmbeddedChannel()
        try! chan.pipeline.syncOperations.addHandler(LineFrameDecoder())
        try! chan.pipeline.syncOperations.addHandler(LineFrameEncoder())
        let client = CMUXClient(channel: chan, requestTimeout: .seconds(1))
        return (chan, client)
    }

    func testCallEncodesRequestAndResolvesOnResponse() async throws {
        let (chan, client) = makeHarness()
        async let result = client.call(method: "workspace.list", params: .object([:]))

        // Pump one round of EmbeddedChannel I/O.
        try await Task.sleep(nanoseconds: 10_000_000)
        let outbound: ByteBuffer = try XCTUnwrap(try chan.readOutbound())
        let outString = outbound.getString(at: 0, length: outbound.readableBytes)!
        XCTAssertTrue(outString.contains("\"method\":\"workspace.list\""))
        XCTAssertTrue(outString.contains("\"id\":1"))

        // Inject a server response with the same id.
        var resp = ByteBufferAllocator().buffer(capacity: 64)
        resp.writeString(#"{"id":1,"ok":true,"result":{"workspaces":[]}}"#)
        try chan.writeInbound(resp)

        let value = try await result
        XCTAssertTrue(value.ok)
    }

    func testTimeoutThrows() async throws {
        let (_, client) = makeHarness()
        do {
            _ = try await client.call(method: "workspace.list", params: .object([:]))
            XCTFail("expected timeout")
        } catch CMUXClientError.timeout {
            // ok
        }
    }

    func testServerPushDispatchesToHandler() async throws {
        let (chan, client) = makeHarness()
        let exp = expectation(description: "push delivered")
        await client.onEventStream { frame in
            if case .event = frame { exp.fulfill() }
        }
        var buf = ByteBufferAllocator().buffer(capacity: 64)
        buf.writeString(#"{"type":"event","category":"system","name":"x","payload":{}}"#)
        try chan.writeInbound(buf)
        await fulfillment(of: [exp], timeout: 1.0)
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter CMUXClientTests.CMUXClientTests`
Expected: FAIL.

- [ ] **Step 3: Implement `CMUXClient.swift`**

```swift
import Foundation
import NIOCore
import NIOFoundationCompat
import Logging
import SharedKit

public enum CMUXClientError: Error, Equatable {
    case timeout
    case rpc(RPCError)
    case decoding(String)
    case channelClosed
}

public actor CMUXClient {
    private let channel: Channel
    private let requestTimeout: TimeAmount
    private let logger = Logger(label: "CMUXClient")

    private var nextId: Int64 = 1
    private var pending: [Int64: CheckedContinuation<RPCResponse, Error>] = [:]
    private var pushHandler: (@Sendable (PushFrame) -> Void)?

    public init(channel: Channel, requestTimeout: TimeAmount = .seconds(5)) {
        self.channel = channel
        self.requestTimeout = requestTimeout
        Task { await self.installInboundHandler() }
    }

    public func onEventStream(_ handler: @escaping @Sendable (PushFrame) -> Void) {
        self.pushHandler = handler
    }

    @discardableResult
    public func call(method: String, params: JSONValue) async throws -> RPCResponse {
        let id = nextId; nextId += 1
        let req = RPCRequest(id: id, method: method, params: params)
        let body = try JSONEncoder().encode(req)
        var buf = channel.allocator.buffer(capacity: body.count)
        buf.writeBytes(body)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RPCResponse, Error>) in
            self.pending[id] = cont
            channel.writeAndFlush(buf).whenFailure { err in
                Task { await self.fail(id: id, with: err) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(self.requestTimeout.nanoseconds))
                await self.timeoutIfPending(id: id)
            }
        }
    }

    private func fail(id: Int64, with error: Error) {
        if let c = pending.removeValue(forKey: id) { c.resume(throwing: error) }
    }

    private func timeoutIfPending(id: Int64) {
        if let c = pending.removeValue(forKey: id) { c.resume(throwing: CMUXClientError.timeout) }
    }

    private func installInboundHandler() async {
        let handler = ClientInboundBridge(client: self)
        try? await channel.pipeline.addHandler(handler).get()
    }

    fileprivate func deliver(line: ByteBuffer) {
        guard let str = line.getString(at: 0, length: line.readableBytes),
              let data = str.data(using: .utf8) else { return }
        // Try response first (has "id"), else push frame.
        if let resp = try? JSONDecoder().decode(RPCResponse.self, from: data),
           let cont = pending.removeValue(forKey: resp.id) {
            cont.resume(returning: resp)
            return
        }
        if let push = try? JSONDecoder().decode(PushFrame.self, from: data) {
            pushHandler?(push)
            return
        }
        logger.warning("unrecognised message: \(str)")
    }
}

private final class ClientInboundBridge: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private weak var client: CMUXClient?
    init(client: CMUXClient) { self.client = client }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = self.unwrapInboundIn(data)
        let captured = buf
        Task { await self.client?.deliver(line: captured) }
    }
}
```

- [ ] **Step 4: Run — expect green**

Run: `swift test --filter CMUXClientTests.CMUXClientTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CMUXClient/CMUXClient.swift Tests/CMUXClientTests/CMUXClientTests.swift
git commit -m "M2.2: CMUXClient request correlation + push fanout"
```

---

## Task 3 — Typed wrappers for v1 cmux methods (`CMUXMethods.swift`)

Spec section 6.3. One method one wrapper, decoded into typed Swift values where useful.

**Files:**
- Create: `Sources/CMUXClient/CMUXMethods.swift`
- Test:   `Tests/CMUXClientTests/CMUXMethodsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import NIOCore
import NIOEmbedded
import SharedKit
@testable import CMUXClient

final class CMUXMethodsTests: XCTestCase {
    func testWorkspaceListDecodesSnakeCase() async throws {
        let chan = EmbeddedChannel()
        try chan.pipeline.syncOperations.addHandler(LineFrameDecoder())
        try chan.pipeline.syncOperations.addHandler(LineFrameEncoder())
        let client = CMUXClient(channel: chan, requestTimeout: .seconds(1))

        async let result = client.workspaceList()
        try await Task.sleep(nanoseconds: 5_000_000)
        let _: ByteBuffer = try XCTUnwrap(try chan.readOutbound())
        var resp = ByteBufferAllocator().buffer(capacity: 256)
        resp.writeString(#"""
        {"id":1,"ok":true,"result":{"workspaces":[{"id":"w","name":"n","surfaces":[],"last_activity":1000}]}}
        """#)
        try chan.writeInbound(resp)
        let workspaces = try await result
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces[0].name, "n")
        XCTAssertEqual(workspaces[0].lastActivity, 1000)
    }

    func testSurfaceSendKeyEncodesViaKeyEncoder() async throws {
        let chan = EmbeddedChannel()
        try chan.pipeline.syncOperations.addHandler(LineFrameDecoder())
        try chan.pipeline.syncOperations.addHandler(LineFrameEncoder())
        let client = CMUXClient(channel: chan, requestTimeout: .seconds(1))

        async let _ = client.surfaceSendKey(workspaceId: "w", surfaceId: "s",
                                            key: .named("c", modifiers: [.ctrl]))
        try await Task.sleep(nanoseconds: 5_000_000)
        let outbound: ByteBuffer = try XCTUnwrap(try chan.readOutbound())
        let s = outbound.getString(at: 0, length: outbound.readableBytes)!
        XCTAssertTrue(s.contains("surface.send_key"))
        XCTAssertTrue(s.contains("\"key\":\"ctrl+c\""))
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter CMUXClientTests.CMUXMethodsTests`
Expected: FAIL.

- [ ] **Step 3: Implement `CMUXMethods.swift`**

```swift
import Foundation
import SharedKit

extension CMUXClient {
    public func workspaceList() async throws -> [Workspace] {
        let resp = try await call(method: "workspace.list", params: .object([:]))
        return try resp.unwrapResult().decode([String: [Workspace]].self)["workspaces"] ?? []
    }

    public func workspaceCreate(name: String) async throws -> Workspace {
        let resp = try await call(method: "workspace.create",
                                  params: .object(["name": .string(name)]))
        return try resp.unwrapResult().decode(Workspace.self)
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
        return try resp.unwrapResult().decode([String: [Surface]].self)["surfaces"] ?? []
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
        let resp = try await call(method: "surface.read_text",
                                  params: .object([
                                      "workspace_id": .string(workspaceId),
                                      "surface_id": .string(surfaceId),
                                      "lines": .int(Int64(lines)),
                                  ]))
        return try resp.unwrapResult().decode(Screen.self)
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

// MARK: - JSONValue → Decodable bridge

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
```

- [ ] **Step 4: Run — expect green**

Run: `swift test --filter CMUXClientTests.CMUXMethodsTests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CMUXClient/CMUXMethods.swift Tests/CMUXClientTests/CMUXMethodsTests.swift
git commit -m "M2.3: typed wrappers for cmux v1 methods"
```

---

## Task 4 — `EventStream` long-lived subscription

Spec section 6.3 — relay holds **one** `events.stream` connection to cmux per process and fans it out to all WS clients. The `EventStream` helper keeps a request alive and re-subscribes if the underlying socket drops.

**Files:**
- Create: `Sources/CMUXClient/EventStream.swift`
- Test:   `Tests/CMUXClientTests/EventStreamTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import NIOCore
import NIOEmbedded
import SharedKit
@testable import CMUXClient

final class EventStreamTests: XCTestCase {
    func testForwardsEvents() async throws {
        let chan = EmbeddedChannel()
        try chan.pipeline.syncOperations.addHandler(LineFrameDecoder())
        try chan.pipeline.syncOperations.addHandler(LineFrameEncoder())
        let client = CMUXClient(channel: chan, requestTimeout: .seconds(1))

        var seen: [EventFrame] = []
        let stream = EventStream(client: client) { frame in seen.append(frame) }
        await stream.start(categories: [.notification])

        var buf = ByteBufferAllocator().buffer(capacity: 128)
        buf.writeString(#"""
        {"type":"event","category":"notification","name":"notification.created","payload":{"id":"n-1"}}
        """#)
        try chan.writeInbound(buf)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.name, "notification.created")
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter CMUXClientTests.EventStreamTests`
Expected: FAIL.

- [ ] **Step 3: Implement `EventStream.swift`**

```swift
import Foundation
import SharedKit

public actor EventStream {
    private let client: CMUXClient
    private let sink: @Sendable (EventFrame) -> Void
    private var started = false

    public init(client: CMUXClient, sink: @escaping @Sendable (EventFrame) -> Void) {
        self.client = client; self.sink = sink
    }

    public func start(categories: [EventCategory]) async {
        guard !started else { return }
        started = true
        let sink = self.sink
        await client.onEventStream { frame in
            if case .event(let ev) = frame { sink(ev) }
        }
        let cats: JSONValue = .array(categories.map { .string($0.rawValue) })
        // Fire-and-forget: cmux replies once with ok and then keeps pushing events.
        _ = try? await client.call(method: "events.stream", params: .object(["categories": cats]))
    }
}
```

- [ ] **Step 4: Run — expect green**

Run: `swift test --filter CMUXClientTests.EventStreamTests`
Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/CMUXClient/EventStream.swift Tests/CMUXClientTests/EventStreamTests.swift
git commit -m "M2.4: EventStream — single long-lived events.stream"
```

---

## Task 5 — `ScreenHasher` (shared SHA256-truncated hash)

Spec section 6.4 — `screen.checksum` must be reproducible on the iOS side. Use SHA256 over the canonical row join, truncated to first 16 hex chars.

**Files:**
- Create: `Sources/SharedKit/ScreenHasher.swift`
- Test:   `Tests/SharedKitTests/ScreenHasherTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import SharedKit

@Suite("ScreenHasher")
struct ScreenHasherTests {
    @Test func sameScreenHashesEqual() {
        let a = Screen(rev: 1, rows: ["x","y"], cols: 1, cursor: .init(x: 0, y: 0))
        let b = a
        #expect(ScreenHasher.hash(a) == ScreenHasher.hash(b))
    }

    @Test func cursorChangeChangesHash() {
        let a = Screen(rev: 1, rows: ["x"], cols: 1, cursor: .init(x: 0, y: 0))
        var b = a; b.cursor = .init(x: 1, y: 0)
        #expect(ScreenHasher.hash(a) != ScreenHasher.hash(b))
    }

    @Test func hashIs16HexChars() {
        let h = ScreenHasher.hash(Screen(rev: 0, rows: [], cols: 0, cursor: .init(x: 0, y: 0)))
        #expect(h.count == 16)
        #expect(h.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func rowHashIs16HexChars() {
        let h = ScreenHasher.rowHash("hello world")
        #expect(h.count == 16)
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter SharedKitTests.ScreenHasherTests`
Expected: FAIL.

- [ ] **Step 3: Implement `ScreenHasher.swift`**

```swift
import Foundation
import CryptoKit

public enum ScreenHasher {
    /// Stable hash over the full screen state (rows + cursor). Used for the
    /// `screen.checksum` push frame: client and server must agree on this.
    public static func hash(_ screen: Screen) -> String {
        var hasher = SHA256()
        for row in screen.rows {
            hasher.update(data: Data(row.utf8))
            hasher.update(data: Data([0x0A]))
        }
        hasher.update(data: Data([0xFF]))
        var cursorBytes = withUnsafeBytes(of: screen.cursor.x.littleEndian) { Data($0) }
        cursorBytes.append(contentsOf: withUnsafeBytes(of: screen.cursor.y.littleEndian) { Array($0) })
        hasher.update(data: cursorBytes)
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Per-row hash for DiffEngine row-change detection. Same algorithm.
    public static func rowHash(_ row: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(row.utf8))
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
```

(Note: SharedKit gains a `CryptoKit` dependency. CryptoKit is part of the system on macOS 10.15+ / iOS 13+, so no `Package.swift` change is needed.)

- [ ] **Step 4: Run — expect green**

Run: `swift test --filter SharedKitTests.ScreenHasherTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SharedKit/ScreenHasher.swift Tests/SharedKitTests/ScreenHasherTests.swift
git commit -m "M2.5: ScreenHasher (shared SHA256 truncated)"
```

---

## Task 6 — `RowState` per-surface state

`RowState` keeps the last-known row hashes and cursor for one subscribed surface so DiffEngine can compare snapshot-to-snapshot.

**Files:**
- Create: `Sources/RelayCore/RowState.swift`
- Test:   `Tests/DiffEngineTests/RowStateTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import RelayCore
import SharedKit

@Suite("RowState")
struct RowStateTests {
    @Test func ingestProducesEmptyOpsOnFirstCall() {
        var state = RowState()
        let scr = Screen(rev: 1, rows: ["a","b"], cols: 1, cursor: .init(x: 0, y: 0))
        let ops = state.ingest(snapshot: scr)
        // First call should emit a full snapshot (clear + rows + cursor).
        #expect(ops.contains(.clear))
        #expect(ops.contains(.row(y: 0, text: "a")))
        #expect(ops.contains(.row(y: 1, text: "b")))
    }

    @Test func subsequentEqualSnapshotIsEmpty() {
        var state = RowState()
        let scr = Screen(rev: 1, rows: ["a"], cols: 1, cursor: .init(x: 0, y: 0))
        _ = state.ingest(snapshot: scr)
        let ops = state.ingest(snapshot: scr)
        #expect(ops.isEmpty)
    }

    @Test func onlyChangedRowsEmit() {
        var state = RowState()
        _ = state.ingest(snapshot: Screen(rev: 1, rows: ["a","b","c"], cols: 1,
                                          cursor: .init(x: 0, y: 0)))
        let ops = state.ingest(snapshot: Screen(rev: 2, rows: ["a","B","c"], cols: 1,
                                                cursor: .init(x: 0, y: 0)))
        #expect(ops == [.row(y: 1, text: "B")])
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter DiffEngineTests.RowStateTests`
Expected: FAIL.

- [ ] **Step 3: Implement `RowState.swift`**

```swift
import Foundation
import SharedKit

public struct RowState {
    private var rowHashes: [String] = []
    private var cursor: CursorPos = .init(x: -1, y: -1)
    private var initialised = false

    public init() {}

    public mutating func ingest(snapshot: Screen) -> [DiffOp] {
        if !initialised {
            initialised = true
            rowHashes = snapshot.rows.map(ScreenHasher.rowHash)
            cursor = snapshot.cursor
            var ops: [DiffOp] = [.clear]
            for (i, row) in snapshot.rows.enumerated() { ops.append(.row(y: i, text: row)) }
            ops.append(.cursor(x: snapshot.cursor.x, y: snapshot.cursor.y))
            return ops
        }
        var ops: [DiffOp] = []
        if snapshot.rows.count != rowHashes.count {
            ops.append(.clear)
            rowHashes = snapshot.rows.map(ScreenHasher.rowHash)
            for (i, row) in snapshot.rows.enumerated() { ops.append(.row(y: i, text: row)) }
        } else {
            for i in 0..<snapshot.rows.count {
                let h = ScreenHasher.rowHash(snapshot.rows[i])
                if h != rowHashes[i] {
                    rowHashes[i] = h
                    ops.append(.row(y: i, text: snapshot.rows[i]))
                }
            }
        }
        if snapshot.cursor != cursor {
            cursor = snapshot.cursor
            ops.append(.cursor(x: snapshot.cursor.x, y: snapshot.cursor.y))
        }
        return ops
    }
}
```

- [ ] **Step 4: Run — expect green**

Run: `swift test --filter DiffEngineTests.RowStateTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
rm -f Sources/RelayCore/.gitkeep
git add Sources/RelayCore/RowState.swift Tests/DiffEngineTests/RowStateTests.swift
git commit -m "M2.6: RowState diff stream"
```

---

## Task 7 — `DiffEngine` (polling + idle adaptation + fps cap)

Spec section 6.4. Wraps `RowState` with a polling timer driven by SwiftNIO's event loop. Configurable target fps, idle drop, hard caps.

**Files:**
- Create: `Sources/RelayCore/DiffEngine.swift`
- Test:   `Tests/DiffEngineTests/DiffEngineTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import NIOCore
import NIOEmbedded
import SharedKit
@testable import RelayCore

final class DiffEngineBehaviorTests: XCTestCase {
    /// Static fake reader: returns a queued sequence of snapshots in order.
    private final class StaticReader: SurfaceReader, @unchecked Sendable {
        var snapshots: [Screen]
        init(_ snapshots: [Screen]) { self.snapshots = snapshots }
        func read(workspaceId: String, surfaceId: String, lines: Int) async throws -> Screen {
            if snapshots.isEmpty { return Screen(rev: 0, rows: [], cols: 0, cursor: .init(x: 0, y: 0)) }
            return snapshots.removeFirst()
        }
    }

    func testEmitsFullSnapshotThenDiffs() async throws {
        let reader = StaticReader([
            Screen(rev: 1, rows: ["a","b"], cols: 1, cursor: .init(x: 0, y: 0)),
            Screen(rev: 2, rows: ["a","B"], cols: 1, cursor: .init(x: 1, y: 1)),
        ])
        var emitted: [[DiffOp]] = []
        let engine = DiffEngine(reader: reader, fps: 100, idleFps: 10,
                                workspaceId: "w", surfaceId: "s", lines: 2,
                                clock: FakeClock())
        engine.onDiff = { emitted.append($0) }
        try await engine.tick()
        try await engine.tick()
        XCTAssertTrue(emitted[0].contains(.clear))
        XCTAssertEqual(emitted[1], [.row(y: 1, text: "B"), .cursor(x: 1, y: 1)])
    }

    func testIdleAdaptationAfterNoInput() async throws {
        let reader = StaticReader([
            Screen(rev: 1, rows: ["a"], cols: 1, cursor: .init(x: 0, y: 0)),
            Screen(rev: 2, rows: ["a"], cols: 1, cursor: .init(x: 0, y: 0)),
        ])
        let clock = FakeClock()
        let engine = DiffEngine(reader: reader, fps: 30, idleFps: 5,
                                workspaceId: "w", surfaceId: "s", lines: 1,
                                clock: clock)
        try await engine.tick()
        clock.advance(by: 2.0)              // > 1.5s of no input
        try await engine.tick()
        XCTAssertEqual(engine.currentFps, 5)
        engine.noteUserInput()
        XCTAssertEqual(engine.currentFps, 30)
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter DiffEngineTests.DiffEngineBehaviorTests`
Expected: FAIL.

- [ ] **Step 3: Implement `DiffEngine.swift`**

```swift
import Foundation
import SharedKit

public protocol SurfaceReader: Sendable {
    func read(workspaceId: String, surfaceId: String, lines: Int) async throws -> Screen
}

public protocol Clock: Sendable {
    var now: TimeInterval { get }
}
public final class SystemClock: Clock {
    public init() {}
    public var now: TimeInterval { Date().timeIntervalSince1970 }
}
public final class FakeClock: Clock, @unchecked Sendable {
    private var t: TimeInterval = 0
    public init() {}
    public var now: TimeInterval { t }
    public func advance(by dt: TimeInterval) { t += dt }
}

public final class DiffEngine: @unchecked Sendable {
    public let workspaceId: String
    public let surfaceId: String
    public let lines: Int
    public let activeFps: Int
    public let idleFps: Int
    public let idleAfter: TimeInterval = 1.5

    public var onDiff: (([DiffOp]) -> Void)?
    public var onChecksum: ((String, Int) -> Void)?
    public private(set) var rev: Int = 0
    public private(set) var currentFps: Int

    private let reader: SurfaceReader
    private let clock: Clock
    private var state = RowState()
    private var lastInput: TimeInterval
    private var lastChecksumAt: TimeInterval = 0

    public init(reader: SurfaceReader,
                fps: Int, idleFps: Int,
                workspaceId: String, surfaceId: String, lines: Int,
                clock: Clock = SystemClock())
    {
        self.reader = reader
        self.activeFps = fps
        self.idleFps = idleFps
        self.currentFps = fps
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.lines = lines
        self.clock = clock
        self.lastInput = clock.now
    }

    public func noteUserInput() {
        lastInput = clock.now
        currentFps = activeFps
    }

    /// Run one polling tick. In production wired to a NIO TimerTask at 1/currentFps.
    public func tick() async throws {
        if clock.now - lastInput > idleAfter { currentFps = idleFps }
        let snapshot = try await reader.read(workspaceId: workspaceId,
                                             surfaceId: surfaceId, lines: lines)
        let ops = state.ingest(snapshot: snapshot)
        if !ops.isEmpty {
            rev &+= 1
            onDiff?(ops)
        }
        if clock.now - lastChecksumAt >= 5.0 {
            lastChecksumAt = clock.now
            onChecksum?(ScreenHasher.hash(snapshot), rev)
        }
    }
}
```

- [ ] **Step 4: Run — expect green**

Run: `swift test --filter DiffEngineTests.DiffEngineBehaviorTests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RelayCore/DiffEngine.swift Tests/DiffEngineTests/DiffEngineTests.swift
git commit -m "M2.7: DiffEngine polling + idle fps + checksum cadence"
```

---

## Task 8 — Per-device FPS cap (60 Hz across all surfaces)

Spec section 6.4 caps any one device at 60 Hz total. This is a cross-engine throttle, separate from the per-engine cap, so it lives outside `DiffEngine`.

**Files:**
- Create: `Sources/RelayCore/DeviceFpsBudget.swift`
- Test:   `Tests/DiffEngineTests/DeviceFpsBudgetTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RelayCore

final class DeviceFpsBudgetTests: XCTestCase {
    func testAllowsUntilCap() {
        let clock = FakeClock()
        let budget = DeviceFpsBudget(maxPerSecond: 5, clock: clock)
        for _ in 0..<5 { XCTAssertTrue(budget.consumeFrame()) }
        XCTAssertFalse(budget.consumeFrame())
    }

    func testWindowSlides() {
        let clock = FakeClock()
        let budget = DeviceFpsBudget(maxPerSecond: 2, clock: clock)
        XCTAssertTrue(budget.consumeFrame())
        XCTAssertTrue(budget.consumeFrame())
        XCTAssertFalse(budget.consumeFrame())
        clock.advance(by: 1.001)
        XCTAssertTrue(budget.consumeFrame())
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter DiffEngineTests.DeviceFpsBudgetTests`
Expected: FAIL.

- [ ] **Step 3: Implement `DeviceFpsBudget.swift`**

```swift
import Foundation

public final class DeviceFpsBudget: @unchecked Sendable {
    public let maxPerSecond: Int
    private let clock: Clock
    private var stamps: [TimeInterval] = []
    public init(maxPerSecond: Int, clock: Clock = SystemClock()) {
        self.maxPerSecond = maxPerSecond; self.clock = clock
    }

    public func consumeFrame() -> Bool {
        let now = clock.now
        stamps.removeAll { now - $0 > 1.0 }
        guard stamps.count < maxPerSecond else { return false }
        stamps.append(now)
        return true
    }
}
```

- [ ] **Step 4: Run — expect green**

Run: `swift test --filter DiffEngineTests.DeviceFpsBudgetTests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RelayCore/DeviceFpsBudget.swift Tests/DiffEngineTests/DeviceFpsBudgetTests.swift
git commit -m "M2.8: per-device 60Hz frame budget"
```

---

## Task 9 — Golden ANSI fixtures

Spec section 6.4 — six representative fixtures that lock current behaviour. Adding the remaining 24 fixtures from real cmux captures is part of M2 task 10; these six gate the milestone.

**Files:**
- Create: `Tests/DiffEngineTests/Fixtures/01-vim-insert.json`
- Create: `Tests/DiffEngineTests/Fixtures/02-ls-colors.json`
- Create: `Tests/DiffEngineTests/Fixtures/03-cursor-only.json`
- Create: `Tests/DiffEngineTests/Fixtures/04-row-extension.json`
- Create: `Tests/DiffEngineTests/Fixtures/05-clear-resize.json`
- Create: `Tests/DiffEngineTests/Fixtures/06-htop-refresh.json`
- Create: `Tests/DiffEngineTests/GoldenFixturesTests.swift`

Fixture format (one JSON file per scenario):

```json
{
  "before": { "rev": 1, "rows": ["..."], "cols": 80, "cursor": {"x": 0, "y": 0} },
  "after":  { "rev": 2, "rows": ["..."], "cols": 80, "cursor": {"x": 0, "y": 0} },
  "expected_ops": [
    { "op": "row", "y": 0, "text": "..." },
    { "op": "cursor", "x": 0, "y": 0 }
  ]
}
```

- [ ] **Step 1: Author the six fixtures by hand**

For `01-vim-insert.json`, capture a vim transition from normal mode to insert mode with `i`:

```json
{
  "before": {
    "rev": 1, "rows": ["~","~","-- NORMAL --"], "cols": 12,
    "cursor": {"x": 0, "y": 0}
  },
  "after": {
    "rev": 2, "rows": ["~","~","-- INSERT --"], "cols": 12,
    "cursor": {"x": 0, "y": 0}
  },
  "expected_ops": [
    { "op": "row", "y": 2, "text": "-- INSERT --" }
  ]
}
```

Author the remaining five with similar minimal contents — keep them small so the golden test failure is obviously diffable. Each must hit a distinct path:

| File | Scenario |
|---|---|
| `02-ls-colors.json` | row gains an SGR escape `[34mfile.txt[0m` (escape preserved verbatim) |
| `03-cursor-only.json` | identical rows, only cursor changes |
| `04-row-extension.json` | row count grows from 3 → 5 (forces `.clear` + full re-emit) |
| `05-clear-resize.json` | cols change 80 → 120 (still triggers `.clear` since rowHashes change wholesale) |
| `06-htop-refresh.json` | half the rows changed simultaneously |

- [ ] **Step 2: Write the harness test**

`Tests/DiffEngineTests/GoldenFixturesTests.swift`:

```swift
import Testing
import Foundation
import SharedKit
@testable import RelayCore

struct Fixture: Decodable {
    let before: Screen
    let after: Screen
    let expectedOps: [DiffOp]
    enum CodingKeys: String, CodingKey { case before, after, expectedOps = "expected_ops" }
}

@Suite("DiffEngine golden fixtures")
struct GoldenFixturesTests {
    static var allFixtureURLs: [URL] {
        let bundle = Bundle.module
        return (bundle.urls(forResourcesWithExtension: "json", subdirectory: "Fixtures") ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test(arguments: GoldenFixturesTests.allFixtureURLs)
    func reproducesExpectedOps(url: URL) throws {
        let data = try Data(contentsOf: url)
        let fix  = try JSONDecoder().decode(Fixture.self, from: data)
        var state = RowState()
        _ = state.ingest(snapshot: fix.before)
        let actual = state.ingest(snapshot: fix.after)
        #expect(actual == fix.expectedOps,
                "\(url.lastPathComponent): expected \(fix.expectedOps), got \(actual)")
    }
}
```

- [ ] **Step 3: Run — expect green**

Run: `swift test --filter DiffEngineTests.GoldenFixturesTests`
Expected: 6 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Tests/DiffEngineTests/Fixtures Tests/DiffEngineTests/GoldenFixturesTests.swift
git commit -m "M2.9: 6 golden ANSI fixtures + parametrised harness"
```

---

## Task 10 — Reverse-direction integration smoke (CMUXClient → real cmux)

Without a fully-built relay yet, we still want a one-shot live-cmux integration check.

**Files:**
- Create: `Tests/CMUXClientTests/LiveSocketSmokeTests.swift`

- [ ] **Step 1: Write the smoke test (gated by env var)**

```swift
import XCTest
import NIOCore
import NIOPosix
import SharedKit
@testable import CMUXClient

final class LiveSocketSmokeTests: XCTestCase {
    func testWorkspaceListAgainstRealCmux() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CMUX_LIVE"] != "1",
                      "set CMUX_LIVE=1 to run")
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let chan = try await UnixSocketChannel(path: "/tmp/cmux.sock", group: group)
            .connect { _ in group.next().makeSucceededFuture(()) }
        let client = CMUXClient(channel: chan, requestTimeout: .seconds(5))
        let workspaces = try await client.workspaceList()
        print("live workspaces: \(workspaces.map(\.name))")
        XCTAssertNotNil(workspaces)
    }
}
```

- [ ] **Step 2: Run on the dev mac with cmux running**

```bash
CMUX_LIVE=1 swift test --filter CMUXClientTests.LiveSocketSmokeTests
```
Expected: prints workspace names. Without `CMUX_LIVE=1` the test self-skips so CI does not require cmux.

- [ ] **Step 3: Commit**

```bash
git add Tests/CMUXClientTests/LiveSocketSmokeTests.swift
git commit -m "M2.10: CMUX_LIVE=1 smoke test against /tmp/cmux.sock"
```

---

## Exit criteria

```bash
swift test --filter SharedKitTests 2>&1 | tail -5
swift test --filter CMUXClientTests 2>&1 | tail -5
swift test --filter DiffEngineTests 2>&1 | tail -5
swift build -c release 2>&1 | tail -3
```

Required:
- `0 failures` for SharedKit, CMUXClient, DiffEngine suites
- `swift build -c release` clean (no warnings)
- With cmux running: `CMUX_LIVE=1 swift test --filter LiveSocketSmokeTests` prints non-empty workspace list

## Self-review

- [ ] **Coverage:** every cmux v1 method in spec section 6.3 has a typed wrapper in `CMUXMethods.swift`. DiffEngine emits `clear`/`row`/`cursor` per spec section 6.4. `screen.checksum` cadence (5 s) is exercised in DiffEngineTests.
- [ ] **Placeholder scan:** `grep -RnE "TODO|FIXME|tbd|placeholder" Sources/CMUXClient Sources/RelayCore` returns no hits.
- [ ] **Type consistency:** `Screen.cursor` vs `CursorPos` matches throughout. `DiffEngine.activeFps`/`idleFps` reflect spec defaults (15/5) — defaults are passed by `RelayCore.ConfigLoader` in M3.

## Merge

```bash
git checkout main
git merge --ff-only m2-cmux-diff
git branch -d m2-cmux-diff
```

Pick up M3 next: `2026-05-09-m3-relay-server.md`.
