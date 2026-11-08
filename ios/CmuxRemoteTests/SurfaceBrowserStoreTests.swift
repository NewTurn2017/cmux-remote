import Foundation
import SharedKit
import Testing
import UIKit
@testable import CmuxRemote

@Suite("SurfaceBrowserStoreTests", .serialized, .timeLimit(.minutes(1)))
struct SurfaceBrowserStoreTests {
    private let capture = RemoteRPCMethod.surfaceBrowserCapture.rawValue

    @MainActor
    private func makeStore(
        _ rpc: DocumentRPCStub,
        sleeper: FakeBrowserRefreshSleeper = FakeBrowserRefreshSleeper(),
        decoder: any BrowserCaptureDecoding = ImageIOBrowserCaptureDecoder()
    ) -> SurfaceBrowserStore {
        SurfaceBrowserStore(
            rpc: rpc,
            sleeper: sleeper,
            decoder: decoder,
            baseIntervalSeconds: 2,
            now: { BrowserFixtures.fixedNow }
        )
    }

    @MainActor
    private func startLoop(_ store: SurfaceBrowserStore, surfaceID: String = "web") -> Task<Void, Never> {
        Task { await store.runRefreshLoop(workspaceID: "ws", surfaceID: surfaceID, isConnected: true, isActive: true) }
    }

    /// Requests a manual capture held at `gate` and waits until it reaches the relay. Reaching
    /// it proves the loop finished handling the previous capture.
    @MainActor
    private func probe(_ store: SurfaceBrowserStore, _ rpc: DocumentRPCStub, gate: String) async {
        await rpc.enqueue(.gate(gate), for: capture)
        store.refreshNow(workspaceID: "ws", surfaceID: "web", isConnected: true)
        await rpc.waitUntilReached(gate)
    }

    // MARK: (a) old relays keep the card

    @Test
    func testMissingCapabilityKeepsCardAndSendsNoRPC() async {
        let browser = Surface(id: "web", title: "localhost:3000", index: 0, type: "browser")
        let markdown = Surface(id: "md", title: "README.md", index: 1, type: "markdown")
        let terminal = Surface(id: "sh", title: "shell", index: 2, type: "terminal")

        #expect(!SurfaceSelectionPolicy.showsBrowser(for: browser, browsersEnabled: false))
        #expect(SurfaceSelectionPolicy.showsBrowser(for: browser, browsersEnabled: true))
        #expect(!SurfaceSelectionPolicy.showsBrowser(for: markdown, browsersEnabled: true))
        #expect(!SurfaceSelectionPolicy.showsBrowser(for: terminal, browsersEnabled: true))
        #expect(!SurfaceSelectionPolicy.showsDocument(for: browser, documentsEnabled: true))

        let rpc = DocumentRPCStub()
        _ = await MainActor.run { makeStore(rpc) }
        #expect(await rpc.callCount(method: capture) == 0)
    }

    @Test @MainActor
    func testMethodNotFoundFallsBackToCardAndPausesRefresh() async {
        let rpc = DocumentRPCStub()
        let sleeper = FakeBrowserRefreshSleeper()
        let store = makeStore(rpc, sleeper: sleeper)
        await rpc.enqueue(.gate("c1"), for: capture)
        let loop = startLoop(store)
        await rpc.waitUntilReached("c1")
        await rpc.release("c1", with: BrowserFixtures.error(RemoteErrorCode.methodNotFound.rawValue))

        await probe(store, rpc, gate: "c2")
        #expect(store.state == .unsupported)
        #expect(await sleeper.requested.isEmpty)

        loop.cancel()
        await rpc.release("c2", with: BrowserFixtures.error(RemoteErrorCode.methodNotFound.rawValue))
        await loop.value
    }

    // MARK: (b) a successful capture

    @Test @MainActor
    func testCaptureSuccessPublishesImageURLAndTitle() async throws {
        let rpc = DocumentRPCStub()
        let sleeper = FakeBrowserRefreshSleeper()
        let store = makeStore(rpc, sleeper: sleeper)
        await rpc.enqueue(.response(try BrowserFixtures.captureResponse(capturedAt: 7)), for: capture)

        let loop = startLoop(store)
        await sleeper.waitForRequests(1)

        let loaded = try #require(store.state.lastCapture)
        #expect(store.state == .loaded(loaded))
        #expect(loaded.pixelSize == CGSize(width: 40, height: 60))
        #expect(loaded.url == "https://example.com/")
        #expect(loaded.title == "Example Domain")
        #expect(loaded.capturedAt == 7)
        #expect(loaded.receivedAt == BrowserFixtures.fixedNow)
        #expect(!store.isCapturing)
        #expect(store.surfaceID == "web")
        #expect(await rpc.params(method: capture) == [.object(["workspace_id": .string("ws"), "surface_id": .string("web")])])

        loop.cancel()
        await loop.value
    }

    @Test @MainActor
    func testMissingTitleFallsBackToSurfaceTitle() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        await rpc.enqueue(.response(try BrowserFixtures.captureResponse(url: nil, title: nil)), for: capture)

        await store.refreshNow(workspaceID: "ws", surfaceID: "web", isConnected: true)?.value

        let loaded = try #require(store.state.lastCapture)
        #expect(loaded.url == nil)
        #expect(loaded.title == nil)
        #expect(loaded.displayTitle(fallback: "localhost:3000") == "localhost:3000")
        let blank = BrowserCapture(image: loaded.image, url: nil, title: "", capturedAt: 1, receivedAt: .now)
        #expect(blank.displayTitle(fallback: "localhost:3000") == "localhost:3000")
        let titled = BrowserCapture(image: loaded.image, url: nil, title: "Docs", capturedAt: 1, receivedAt: .now)
        #expect(titled.displayTitle(fallback: "localhost:3000") == "Docs")
    }

    @Test @MainActor
    func testDecodeRunsOffMainActor() async throws {
        let rpc = DocumentRPCStub()
        let decoder = RecordingBrowserCaptureDecoder()
        let store = makeStore(rpc, decoder: decoder)
        await rpc.enqueue(.response(try BrowserFixtures.captureResponse()), for: capture)

        await store.refreshNow(workspaceID: "ws", surfaceID: "web", isConnected: true)?.value

        #expect(decoder.decodedOnMainThread == [false])
        #expect(store.state.lastCapture != nil)
    }

    @Test @MainActor
    func testStoreKeepsOnlyLatestImage() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        await rpc.enqueue(.response(try BrowserFixtures.captureResponse(capturedAt: 1)), for: capture)
        await rpc.enqueue(.response(try BrowserFixtures.captureResponse(capturedAt: 2)), for: capture)

        weak var first: UIImage?
        await store.refreshNow(workspaceID: "ws", surfaceID: "web", isConnected: true)?.value
        first = store.state.lastCapture?.image
        #expect(first != nil)

        await store.refreshNow(workspaceID: "ws", surfaceID: "web", isConnected: true)?.value
        #expect(store.state.lastCapture?.capturedAt == 2)
        #expect(first == nil)
    }

    @Test @MainActor
    func testStaleResponseAfterSurfaceSwitchIsDiscarded() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        await rpc.enqueue(.gate("a"), for: capture)
        await rpc.enqueue(.response(try BrowserFixtures.captureResponse(title: "B", capturedAt: 2)), for: capture)

        let first = store.refreshNow(workspaceID: "ws", surfaceID: "web-a", isConnected: true)
        await rpc.waitUntilReached("a")
        await store.refreshNow(workspaceID: "ws", surfaceID: "web-b", isConnected: true)?.value
        await rpc.release("a", with: try BrowserFixtures.captureResponse(title: "A", capturedAt: 1))
        await first?.value

        #expect(store.surfaceID == "web-b")
        #expect(store.state.lastCapture?.title == "B")
    }

    // MARK: (c) the refresh loop

    @Test @MainActor
    func testLoopWaitsForPreviousCaptureThenSchedulesTwoSeconds() async throws {
        let rpc = DocumentRPCStub()
        let sleeper = FakeBrowserRefreshSleeper()
        let store = makeStore(rpc, sleeper: sleeper)
        await rpc.enqueue(.gate("c1"), for: capture)

        let loop = startLoop(store)
        await rpc.waitUntilReached("c1")
        #expect(await sleeper.requested.isEmpty)
        #expect(await rpc.callCount(method: capture) == 1)
        #expect(store.isCapturing)

        await rpc.release("c1", with: try BrowserFixtures.captureResponse(capturedAt: 1))
        await sleeper.waitForRequests(1)
        #expect(await sleeper.requested == [2])
        #expect(await rpc.callCount(method: capture) == 1)

        await rpc.enqueue(.gate("c2"), for: capture)
        await sleeper.fireNext()
        await rpc.waitUntilReached("c2")
        #expect(await rpc.callCount(method: capture) == 2)

        loop.cancel()
        await rpc.release("c2", with: try BrowserFixtures.captureResponse(capturedAt: 2))
        await loop.value
        #expect(await rpc.callCount(method: capture) == 2)
    }

    @Test @MainActor
    func testCancellingLoopStopsFurtherCaptures() async throws {
        let rpc = DocumentRPCStub()
        let sleeper = FakeBrowserRefreshSleeper()
        let store = makeStore(rpc, sleeper: sleeper)
        await rpc.enqueue(.response(try BrowserFixtures.captureResponse()), for: capture)

        let loop = startLoop(store)
        await sleeper.waitForRequests(1)
        loop.cancel()
        await loop.value

        #expect(await sleeper.pendingCount == 0)
        #expect(await rpc.callCount(method: capture) == 1)
        #expect(store.state.lastCapture != nil)
    }

    @Test @MainActor
    func testManualRefreshDuringSleepCapturesImmediately() async throws {
        let rpc = DocumentRPCStub()
        let sleeper = FakeBrowserRefreshSleeper()
        let store = makeStore(rpc, sleeper: sleeper)
        await rpc.enqueue(.response(try BrowserFixtures.captureResponse(capturedAt: 1)), for: capture)

        let loop = startLoop(store)
        await sleeper.waitForRequests(1)
        await rpc.enqueue(.gate("c2"), for: capture)
        #expect(store.refreshNow(workspaceID: "ws", surfaceID: "web", isConnected: true) == nil)
        await rpc.waitUntilReached("c2")
        #expect(await sleeper.requested == [2])
        #expect(store.isManualRefreshing)

        await rpc.release("c2", with: try BrowserFixtures.captureResponse(capturedAt: 2))
        await sleeper.waitForRequests(2)
        #expect(!store.isManualRefreshing)
        #expect(await sleeper.requested == [2, 2])
        #expect(store.state.lastCapture?.capturedAt == 2)

        loop.cancel()
        await loop.value
    }

    @Test @MainActor
    func testManualRefreshDuringInFlightRunsExactlyOnceAfter() async throws {
        let rpc = DocumentRPCStub()
        let sleeper = FakeBrowserRefreshSleeper()
        let store = makeStore(rpc, sleeper: sleeper)
        await rpc.enqueue(.gate("c1"), for: capture)

        let loop = startLoop(store)
        await rpc.waitUntilReached("c1")
        store.refreshNow(workspaceID: "ws", surfaceID: "web", isConnected: true)
        store.refreshNow(workspaceID: "ws", surfaceID: "web", isConnected: true)
        #expect(await rpc.callCount(method: capture) == 1)

        await rpc.enqueue(.gate("c2"), for: capture)
        await rpc.release("c1", with: try BrowserFixtures.captureResponse(capturedAt: 1))
        await rpc.waitUntilReached("c2")
        #expect(await sleeper.requested.isEmpty)

        await rpc.release("c2", with: try BrowserFixtures.captureResponse(capturedAt: 2))
        await sleeper.waitForRequests(1)
        #expect(await rpc.callCount(method: capture) == 2)

        loop.cancel()
        await loop.value
    }

    @Test @MainActor
    func testDisconnectedOrInactiveLoopSendsNoCapture() async throws {
        let rpc = DocumentRPCStub()
        let store = makeStore(rpc)
        await rpc.enqueue(.response(try BrowserFixtures.captureResponse()), for: capture)
        await store.refreshNow(workspaceID: "ws", surfaceID: "web", isConnected: true)?.value
        let last = try #require(store.state.lastCapture)

        await store.runRefreshLoop(workspaceID: "ws", surfaceID: "web", isConnected: true, isActive: false)
        #expect(await rpc.callCount(method: capture) == 1)
        #expect(store.state == .loaded(last))

        await store.runRefreshLoop(workspaceID: "ws", surfaceID: "web", isConnected: false, isActive: true)
        #expect(await rpc.callCount(method: capture) == 1)
        #expect(store.state == .failed(.disconnected, last: last))
    }

    // MARK: (d) failures

    @Test @MainActor
    func testTransientFailureKeepsLastImageBacksOffAndSuccessResets() async throws {
        let rpc = DocumentRPCStub()
        let sleeper = FakeBrowserRefreshSleeper()
        let store = makeStore(rpc, sleeper: sleeper)
        await rpc.enqueue(.response(try BrowserFixtures.captureResponse(capturedAt: 1)), for: capture)
        let loop = startLoop(store)
        await sleeper.waitForRequests(1)
        let first = try #require(store.state.lastCapture)

        await rpc.enqueue(.response(BrowserFixtures.error("temporarily_unavailable")), for: capture)
        await sleeper.fireNext()
        await sleeper.waitForRequests(2)
        #expect(store.state == .failed(.temporarilyUnavailable, last: first))

        await rpc.enqueue(.response(BrowserFixtures.error("temporarily_unavailable")), for: capture)
        await sleeper.fireNext()
        await sleeper.waitForRequests(3)
        #expect(await sleeper.requested == [2, 4, 8])
        #expect(store.state.lastCapture == first)

        await rpc.enqueue(.response(try BrowserFixtures.captureResponse(capturedAt: 2)), for: capture)
        await sleeper.fireNext()
        await sleeper.waitForRequests(4)
        #expect(await sleeper.requested == [2, 4, 8, 2])
        #expect(store.state.lastCapture?.capturedAt == 2)

        loop.cancel()
        await loop.value
    }

    @Test @MainActor
    func testNotBrowserDropsImageAndPausesAutoRefresh() async throws {
        let rpc = DocumentRPCStub()
        let sleeper = FakeBrowserRefreshSleeper()
        let store = makeStore(rpc, sleeper: sleeper)
        await rpc.enqueue(.response(try BrowserFixtures.captureResponse()), for: capture)
        let loop = startLoop(store)
        await sleeper.waitForRequests(1)

        await rpc.enqueue(.gate("c2"), for: capture)
        await sleeper.fireNext()
        await rpc.waitUntilReached("c2")
        await rpc.release("c2", with: BrowserFixtures.error(RemoteErrorCode.surfaceNotBrowser.rawValue))

        await probe(store, rpc, gate: "c3")
        #expect(store.state == .failed(.notBrowser, last: nil))
        #expect(await sleeper.requested == [2])

        loop.cancel()
        await rpc.release("c3", with: BrowserFixtures.error(RemoteErrorCode.surfaceNotBrowser.rawValue))
        await loop.value
    }
}
