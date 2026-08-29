import SwiftUI
import SharedKit

struct ContentView: View {
    @State private var selectedTab: AppTab = .workspaces
    @State private var requestedSurfaceId: String?

    let workspaceStore: WorkspaceStore
    let surfaceStore: SurfaceStore
    let notifStore: NotificationStore
    let hostStatusStore: HostStatusStore
    let remoteFiles: RemoteFileFeatureCoordinator
    let onDisconnect: () -> Void
    let onReconnect: () -> Void
    let onTriggerTestNotification: @MainActor () -> TestNotificationResult

    var body: some View {
        Group {
            switch selectedTab {
            case .workspaces:
                WorkspaceListView(store: workspaceStore, notifStore: notifStore) { workspace in
                    notifStore.markWorkspaceSeen(workspace.id)
                    selectedTab = .active
                }
            case .active:
                WorkspaceView(
                    workspaceStore: workspaceStore,
                    surfaceStore: surfaceStore,
                    notifStore: notifStore,
                    hostStatusStore: hostStatusStore,
                    remoteFiles: remoteFiles,
                    preferredSurfaceId: $requestedSurfaceId,
                    onBack: { selectedTab = .workspaces }
                )
            case .inbox:
                NotificationCenterView(store: notifStore) { notification in
                    open(notification: notification)
                }
            case .settings:
                SettingsView(
                    store: workspaceStore,
                    onDisconnect: onDisconnect,
                    onReconnect: onReconnect,
                    onTriggerTestNotification: onTriggerTestNotification
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cmuxRemoteNotificationResponse)) { notification in
            openNotificationUserInfo(notification.userInfo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectedTab != .active {
                FloatingTabBar(selectedTab: $selectedTab, inboxCount: notifStore.unreadCount)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 0)
                    .offset(y: 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(CmuxTheme.canvas.ignoresSafeArea())
    }

    private func open(notification: NotificationRecord) {
        if workspaceStore.workspaces.contains(where: { $0.id == notification.workspaceId }) {
            workspaceStore.selectedId = notification.workspaceId
            requestedSurfaceId = notification.surfaceId
            notifStore.markWorkspaceSeen(notification.workspaceId)
        } else {
            requestedSurfaceId = nil
        }
        selectedTab = .active
    }

    private func openNotificationUserInfo(_ userInfo: [AnyHashable: Any]?) {
        guard let workspaceId = userInfo?["workspace_id"] as? String, !workspaceId.isEmpty else {
            selectedTab = .inbox
            return
        }
        let rawSurfaceId = userInfo?["surface_id"] as? String
        let surfaceId = rawSurfaceId?.isEmpty == true ? nil : rawSurfaceId
        if workspaceStore.workspaces.contains(where: { $0.id == workspaceId }) {
            workspaceStore.selectedId = workspaceId
            requestedSurfaceId = surfaceId
            notifStore.markWorkspaceSeen(workspaceId)
            selectedTab = .active
        } else {
            requestedSurfaceId = nil
            selectedTab = .inbox
        }
    }
}

private enum AppTab: String, CaseIterable, Hashable {
    case workspaces = "Workspaces"
    case active = "Active"
    case inbox = "Inbox"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .workspaces: return "rectangle.stack.fill"
        case .active: return "terminal.fill"
        case .inbox: return "bell.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

private struct FloatingTabBar: View {
    @Binding var selectedTab: AppTab
    let inboxCount: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        selectedTab = tab
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        VStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 18, weight: .semibold))
                            Text(tab.rawValue.uppercased())
                                .cmuxDisplay(9)
                        }
                        .foregroundStyle(selectedTab == tab ? CmuxTheme.accentGreen : CmuxTheme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background {
                            if selectedTab == tab {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(CmuxTheme.surfaceRaised)
                                    .matchedGeometryEffect(id: "selected-tab", in: namespace)
                            }
                        }

                        if tab == .inbox, inboxCount > 0 {
                            Text(inboxCount > 99 ? "99+" : "\(inboxCount)")
                                .cmuxDisplay(9)
                                .foregroundStyle(CmuxTheme.canvas)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(CmuxTheme.accentRed)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                .padding(.top, 4)
                                .padding(.trailing, 10)
                                .accessibilityIdentifier("InboxUnreadBadge")
                                .accessibilityLabel("\(inboxCount) unread inbox notifications")
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
            }
        }
        .padding(6)
        .background(CmuxTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        }
        .shadow(color: CmuxTheme.hardShadow, radius: 24, x: 0, y: 12)
    }

    @Namespace private var namespace
}
