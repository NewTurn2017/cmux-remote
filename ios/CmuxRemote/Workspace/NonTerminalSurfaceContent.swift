import SharedKit
import SwiftUI

struct NonTerminalSurfaceContent: View {
    let surface: Surface
    let workspaceID: String?
    @Bindable var remoteFiles: RemoteFileFeatureCoordinator
    let connection: ConnectionState
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0

    var body: some View {
        if let workspaceID,
           SurfaceSelectionPolicy.showsDocument(for: surface, documentsEnabled: remoteFiles.documentRoutingEnabled)
        {
            SurfaceDocumentView(
                surface: surface,
                workspaceID: workspaceID,
                remoteFiles: remoteFiles,
                connection: connection,
                topContentInset: topContentInset,
                bottomContentInset: bottomContentInset
            )
        } else if let workspaceID,
                  SurfaceSelectionPolicy.showsBrowser(for: surface, browsersEnabled: remoteFiles.browserRoutingEnabled)
        {
            SurfaceBrowserView(
                surface: surface,
                workspaceID: workspaceID,
                remoteFiles: remoteFiles,
                connection: connection,
                topContentInset: topContentInset,
                bottomContentInset: bottomContentInset
            )
        } else {
            NonTerminalSurfaceCard(
                surface: surface,
                topContentInset: topContentInset,
                bottomContentInset: bottomContentInset
            )
        }
    }
}
