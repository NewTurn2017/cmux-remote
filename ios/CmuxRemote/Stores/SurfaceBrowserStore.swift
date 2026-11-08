import Foundation
import Observation
import SharedKit

/// Owns the screenshot of the visible browser tab and its refresh loop.
///
/// At most one capture is in flight. The loop waits for each capture to finish, then waits
/// `baseIntervalSeconds` (longer after failures) before the next one. A manual refresh wakes
/// the wait, or runs once right after the capture already in flight.
@MainActor
@Observable
final class SurfaceBrowserStore {
    private(set) var surfaceID: String?
    private(set) var state: SurfaceBrowserState = .idle
    private(set) var isCapturing = false
    /// True from a manual refresh until the capture it triggered finishes.
    private(set) var isManualRefreshing = false

    let baseIntervalSeconds: Double

    @ObservationIgnored private let rpc: any RPCDispatch
    @ObservationIgnored private let sleeper: any BrowserRefreshSleeper
    @ObservationIgnored private let decoder: any BrowserCaptureDecoding
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var loopToken: UInt64 = 0
    @ObservationIgnored private var loopSurfaceID: String?
    @ObservationIgnored private var wake: (id: UInt64, continuation: CheckedContinuation<Void, Never>)?
    @ObservationIgnored private var wakeSequence: UInt64 = 0

    init(
        rpc: any RPCDispatch,
        sleeper: any BrowserRefreshSleeper = SystemBrowserRefreshSleeper(),
        decoder: any BrowserCaptureDecoding = ImageIOBrowserCaptureDecoder(),
        baseIntervalSeconds: Double = BrowserRefreshPolicy.defaultIntervalSeconds,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rpc = rpc
        self.sleeper = sleeper
        self.decoder = decoder
        self.baseIntervalSeconds = baseIntervalSeconds
        self.now = now
    }

    /// Captures repeatedly while the calling task lives. The browser view runs this from
    /// `.task(id:)`, so leaving the tab, backgrounding the app, or disconnecting cancels it.
    func runRefreshLoop(workspaceID: String, surfaceID: String, isConnected: Bool, isActive: Bool) async {
        select(surfaceID)
        guard isConnected else {
            markDisconnected()
            return
        }
        guard isActive else { return }
        loopToken &+= 1
        let token = loopToken
        loopSurfaceID = surfaceID
        defer {
            if loopToken == token { loopSurfaceID = nil }
        }
        while !Task.isCancelled, loopToken == token, self.surfaceID == surfaceID {
            refreshRequested = false
            await capture(workspaceID: workspaceID, surfaceID: surfaceID)
            guard !Task.isCancelled, loopToken == token, self.surfaceID == surfaceID else { return }
            if refreshRequested { continue }
            await waitForNextCapture(seconds: nextDelaySeconds())
        }
    }

    /// Captures once now. With a loop running it wakes the loop (or queues one capture after
    /// the one in flight) so captures never overlap.
    @discardableResult
    func refreshNow(workspaceID: String, surfaceID: String, isConnected: Bool) -> Task<Void, Never>? {
        select(surfaceID)
        guard isConnected else {
            markDisconnected()
            return nil
        }
        isManualRefreshing = true
        if loopSurfaceID == surfaceID {
            refreshRequested = true
            if inFlight == nil { resumeWake() }
            return nil
        }
        return Task { await self.captureAfterInFlight(workspaceID: workspaceID, surfaceID: surfaceID) }
    }

    func reset() {
        epoch &+= 1
        loopToken &+= 1
        loopSurfaceID = nil
        surfaceID = nil
        state = .idle
        isCapturing = false
        isManualRefreshing = false
        consecutiveFailures = 0
        inFlight = nil
        refreshRequested = false
        resumeWake()
    }

    private func select(_ surfaceID: String) {
        guard self.surfaceID != surfaceID else { return }
        epoch &+= 1
        self.surfaceID = surfaceID
        state = .idle
        isCapturing = false
        isManualRefreshing = false
        consecutiveFailures = 0
        inFlight = nil
        refreshRequested = false
    }

    private func markDisconnected() {
        isManualRefreshing = false
        state = .failed(.disconnected, last: state.lastCapture)
    }

    private func captureAfterInFlight(workspaceID: String, surfaceID: String) async {
        if let inFlight { await inFlight.value }
        guard self.surfaceID == surfaceID else { return }
        isManualRefreshing = true
        await capture(workspaceID: workspaceID, surfaceID: surfaceID)
    }

    private func capture(workspaceID: String, surfaceID: String) async {
        if let inFlight {
            await inFlight.value
            return
        }
        let expectedEpoch = epoch
        let task = Task { await self.performCapture(workspaceID: workspaceID, surfaceID: surfaceID, epoch: expectedEpoch) }
        inFlight = task
        await task.value
    }

    private func performCapture(workspaceID: String, surfaceID: String, epoch expectedEpoch: UInt64) async {
        isCapturing = true
        if case .idle = state { state = .loading }
        let outcome: Result<BrowserCapture, Error>
        do {
            let response = try await rpc.call(
                method: RemoteRPCMethod.surfaceBrowserCapture.rawValue,
                params: .object([
                    "workspace_id": .string(workspaceID),
                    "surface_id": .string(surfaceID),
                ])
            )
            let result = try response.unwrapResult().decode(SurfaceBrowserCaptureResult.self)
            let decoder = self.decoder
            let image = try await Task.detached(priority: .userInitiated) {
                try decoder.decode(result)
            }.value
            outcome = .success(BrowserCapture(
                image: image,
                url: result.url,
                title: result.title,
                capturedAt: result.capturedAt,
                receivedAt: now()
            ))
        } catch {
            outcome = .failure(error)
        }
        guard expectedEpoch == epoch else { return }
        inFlight = nil
        isCapturing = false
        if !refreshRequested { isManualRefreshing = false }
        switch outcome {
        case .success(let capture):
            consecutiveFailures = 0
            state = .loaded(capture)
        case .failure(CmuxRemoteRPCError.rpc(let code, _)) where code == RemoteErrorCode.methodNotFound.rawValue:
            consecutiveFailures = 0
            state = .unsupported
        case .failure(let error):
            let failure = BrowserCaptureFailure(error: error)
            consecutiveFailures += 1
            state = .failed(failure, last: failure.isPersistent ? nil : state.lastCapture)
        }
    }

    /// nil means automatic refresh is paused until a manual refresh wakes the loop.
    private func nextDelaySeconds() -> Double? {
        switch state {
        case .unsupported:
            return nil
        case .failed(let failure, _) where failure.isPersistent:
            return nil
        default:
            return BrowserRefreshPolicy.delaySeconds(
                consecutiveFailures: consecutiveFailures,
                baseSeconds: baseIntervalSeconds
            )
        }
    }

    private func waitForNextCapture(seconds: Double?) async {
        let sleeper = self.sleeper
        await withTaskGroup(of: Void.self) { group in
            if let seconds {
                group.addTask { try? await sleeper.sleep(seconds: seconds) }
            }
            group.addTask { await self.waitForWake() }
            await group.next()
            group.cancelAll()
        }
    }

    private func waitForWake() async {
        wakeSequence &+= 1
        let id = wakeSequence
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if refreshRequested || Task.isCancelled {
                    continuation.resume()
                    return
                }
                wake = (id, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeWake(id: id) }
        }
    }

    private func resumeWake(id: UInt64? = nil) {
        guard let wake, id == nil || wake.id == id else { return }
        self.wake = nil
        wake.continuation.resume()
    }
}
