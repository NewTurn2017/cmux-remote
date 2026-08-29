import Foundation

struct ManualSurfaceRenderClockWaiter {
    let deadline: TimeInterval
    let continuation: CheckedContinuation<Void, Error>
}
