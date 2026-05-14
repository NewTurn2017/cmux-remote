import SwiftUI
import SharedKit

struct ContentView: View {
    @State private var selectedTab: AppTab = .workspaces
    @State private var requestedSurfaceId: String?

    let workspaceStore: WorkspaceStore
    let surfaceStore: SurfaceStore
    let notifStore: NotificationStore
    let onDisconnect: () -> Void
    let onReconnect: () -> Void
    let onTriggerTestNotification: @MainActor () -> TestNotificationResult

    var body: some View {
        Group {
            switch selectedTab {
            case .workspaces:
                WorkspaceListView(store: workspaceStore) { _ in selectedTab = .active }
            case .active:
                WorkspaceView(
                    workspaceStore: workspaceStore,
                    surfaceStore: surfaceStore,
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectedTab != .active {
                FloatingTabBar(selectedTab: $selectedTab, inboxCount: notifStore.items.count)
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
        } else {
            requestedSurfaceId = nil
        }
        selectedTab = .active
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
                                .accessibilityHidden(true)
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
