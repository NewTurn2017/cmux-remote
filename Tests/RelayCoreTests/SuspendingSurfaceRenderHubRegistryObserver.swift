import Foundation
@testable import RelayCore

actor SuspendingSurfaceRenderHubRegistryObserver: SurfaceRenderHubRegistryObserving {
    private var suspensionPoint: SurfaceRenderHubRegistrySuspensionPoint
    private var waiters: [SurfaceRenderHubRegistryObserverWaiter] = []
    private var eventContinuation: AsyncStream<SurfaceRenderHubRegistryObservation>.Continuation?

    init(suspensionPoint: SurfaceRenderHubRegistrySuspensionPoint) {
        self.suspensionPoint = suspensionPoint
    }

    func events() -> AsyncStream<SurfaceRenderHubRegistryObservation> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            eventContinuation = continuation
        }
    }

    func setSuspensionPoint(_ point: SurfaceRenderHubRegistrySuspensionPoint) {
        suspensionPoint = point
    }

    func resumeNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    func acquisitionDidStart(surfaceId: String) async {
        eventContinuation?.yield(.started(surfaceId))
    }

    func acquisitionDidReserve(_ subscription: SurfaceRenderSubscription) async {
        eventContinuation?.yield(.reserved(subscription))
        guard suspensionPoint == .reservation else { return }
        await suspend()
    }

    func acquisitionDidRegister(_ subscription: SurfaceRenderSubscription) async {
        eventContinuation?.yield(.registered(subscription))
        guard suspensionPoint == .registration else { return }
        await suspend()
    }

    private func suspend() async {
        await withCheckedContinuation { continuation in
            waiters.append(SurfaceRenderHubRegistryObserverWaiter(
                continuation: continuation
            ))
        }
    }
}
