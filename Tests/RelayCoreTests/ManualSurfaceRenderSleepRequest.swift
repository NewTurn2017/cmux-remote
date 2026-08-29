import Foundation

struct ManualSurfaceRenderSleepRequest: Equatable, Sendable {
    let seconds: TimeInterval
    let deadline: TimeInterval
}
