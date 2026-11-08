import SharedKit
import SwiftUI

struct SurfaceBrowserView: View {
    let surface: Surface
    let workspaceID: String
    @Bindable var remoteFiles: RemoteFileFeatureCoordinator
    let connection: ConnectionState
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0

    @Environment(\.scenePhase) private var scenePhase

    private var store: SurfaceBrowserStore { remoteFiles.browsers }
    private var isConnected: Bool { connection == .connected }
    private var isActive: Bool { scenePhase == .active }
    private var isCurrentSurface: Bool { store.surfaceID == surface.id }

    var body: some View {
        Group {
            if isCurrentSurface, store.state == .unsupported {
                NonTerminalSurfaceCard(
                    surface: surface,
                    topContentInset: topContentInset,
                    bottomContentInset: bottomContentInset
                )
            } else {
                BrowserViewer(
                    surfaceTitle: surface.title,
                    state: isCurrentSurface ? store.state : .loading,
                    isRefreshing: isCurrentSurface && store.isManualRefreshing,
                    canRefresh: isConnected && isCurrentSurface && !store.isManualRefreshing,
                    onRefresh: refresh,
                    topContentInset: topContentInset,
                    bottomContentInset: bottomContentInset + bottomSafeAreaInset
                )
            }
        }
        .task(id: loopID) {
            await store.runRefreshLoop(
                workspaceID: workspaceID,
                surfaceID: surface.id,
                isConnected: isConnected,
                isActive: isActive
            )
        }
    }

    /// Same accounting as `SurfaceDocumentView`: the workspace ignores the safe area, and the
    /// accessory height it reports excludes the home-indicator area.
    private var bottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    private var loopID: String {
        [
            workspaceID,
            surface.id,
            String(remoteFiles.hostGeneration),
            isConnected ? "connected" : "offline",
            isActive ? "active" : "inactive",
        ].joined(separator: "|")
    }

    private func refresh() {
        store.refreshNow(workspaceID: workspaceID, surfaceID: surface.id, isConnected: isConnected)
    }
}
