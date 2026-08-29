import CMUXClient
import Foundation

/// Sendable result retained by the hub while one source task is in flight.
enum SurfaceRenderReadResult: Sendable {
    case success(CMUXTerminalReadOutcome)
    case failure(String)
    case cancelled
}
