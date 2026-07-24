import SwiftUI
import UIKit
import SharedKit

struct ContentView: View {
    @State private var selectedTab: AppTab = .workspaces
    @State private var requestedSurfaceId: String?

    let workspaceStore: WorkspaceStore
    let surfaceStore: SurfaceStore
    let notifStore: NotificationStore
    let hostStatusStore: HostStatusStore
    let onDisconnect: () -> Void
    let onReconnect: () -> Void
    let onTriggerTestNotification: @MainActor () -> TestNotificationResult

    var body: some View {
        GeometryReader { proxy in
            if AdaptiveLayout.isPadLandscape(proxy.size) {
                HStack(spacing: 0) {
                    IPadSidebar(selectedTab: $selectedTab, inboxCount: notifStore.unreadCount)
                    Rectangle()
                        .fill(CmuxTheme.divider)
                        .frame(width: 1)
                    selectedContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                selectedContent
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
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cmuxRemoteNotificationResponse)) { notification in
            openNotificationUserInfo(notification.userInfo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CmuxTheme.canvas.ignoresSafeArea())
    }

    @ViewBuilder
    private var selectedContent: some View {
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
                onTerminalPreferencesChanged: {
                    Task { await surfaceStore.refreshSubscriptionPreferences() }
                },
                onTriggerTestNotification: onTriggerTestNotification
            )
        }
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

    var title: String {
        switch self {
        case .workspaces: return L10n.string("Workspaces")
        case .active: return L10n.string("Active")
        case .inbox: return L10n.string("Inbox")
        case .settings: return L10n.string("Settings")
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
                            Text(tab.title.uppercased())
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
                                .accessibilityLabel(L10n.format("%lld unread inbox notifications", inboxCount))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
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

private struct IPadSidebar: View {
    @Binding var selectedTab: AppTab
    let inboxCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("cmux")
                    .cmuxDisplay(22)
                    .foregroundStyle(CmuxTheme.ink)
                Text("remote")
                    .cmuxDisplay(22)
                    .foregroundStyle(CmuxTheme.accentGreen)
            }
            .padding(.horizontal, 18)

            VStack(spacing: 6) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 20)
                            Text(tab.title)
                                .cmuxMono(13, weight: .medium)
                            Spacer()
                            if tab == .inbox, inboxCount > 0 {
                                Text(inboxCount > 99 ? "99+" : "\(inboxCount)")
                                    .cmuxDisplay(9)
                                    .foregroundStyle(CmuxTheme.canvas)
                                    .padding(.horizontal, 5)
                                    .frame(minWidth: 18, minHeight: 18)
                                    .background(CmuxTheme.accentRed)
                                    .clipShape(Capsule())
                            }
                        }
                        .foregroundStyle(selectedTab == tab ? CmuxTheme.accentGreen : CmuxTheme.inkDim)
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .background(selectedTab == tab ? CmuxTheme.surfaceRaised : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                }
            }
            .padding(.horizontal, 10)

            Spacer()
        }
        .padding(.top, 28)
        .frame(width: 190)
        .background(CmuxTheme.surface)
        .accessibilityIdentifier("IPadSidebar")
    }
}
