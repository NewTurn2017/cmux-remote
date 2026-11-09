import SharedKit
import SwiftUI

struct SurfaceDocumentView: View {
    let surface: Surface
    let workspaceID: String
    @Bindable var remoteFiles: RemoteFileFeatureCoordinator
    let connection: ConnectionState
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0

    private var store: SurfaceDocumentStore { remoteFiles.documents }
    private var isConnected: Bool { connection == .connected }
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
                DocumentViewer(
                    title: surface.title,
                    content: viewerContent,
                    isRefreshing: isCurrentSurface && store.isRefreshing,
                    canRefresh: isConnected && isCurrentSurface && !store.isRefreshing && store.state != .loading,
                    onRefresh: refresh,
                    topContentInset: topContentInset,
                    bottomContentInset: bottomContentInset + bottomSafeAreaInset
                )
            }
        }
        .task(id: loadID) {
            await store.open(workspaceID: workspaceID, surfaceID: surface.id, isConnected: isConnected)
        }
    }

    /// The workspace lays this view out ignoring the safe area while the accessory
    /// height it reports excludes the home-indicator area, as in `TerminalView`.
    private var bottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    private var loadID: String {
        [workspaceID, surface.id, String(remoteFiles.hostGeneration), isConnected ? "connected" : "offline"]
            .joined(separator: "|")
    }

    private var viewerContent: DocumentViewer.Content {
        guard isCurrentSurface else { return .loading }
        switch store.state {
        case .idle, .loading, .unsupported: return .loading
        case .loaded(let rendered): return .loaded(rendered)
        case .failed(let failure): return .failed(failure)
        }
    }

    private func refresh() {
        let workspaceID = workspaceID
        let surfaceID = surface.id
        let isConnected = isConnected
        Task { await store.open(workspaceID: workspaceID, surfaceID: surfaceID, isConnected: isConnected) }
    }
}
