import NIOCore
@testable import RelayCore
@testable import RelayServer

/// Bundles exact dependencies for one session-lifecycle test.
struct WebSocketSessionLifecycleFixture {
    let backing: SessionManager
    let manager: ControllableWebSocketSessionManager
    let eventLoop: any EventLoop
    let lifecycle: WebSocketSessionLifecycle
    let attachProbe: RelayServerBoundedStreamProbe<Int>
}
