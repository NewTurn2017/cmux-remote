import SwiftUI
import SharedKit

struct WorkspaceListView: View {
    @Bindable var store: WorkspaceStore
    let notifStore: NotificationStore
    @State private var creating = false
    @State private var newName = ""
    @State private var searchText = ""
    @State private var pendingRenameWorkspace: Workspace?
    @State private var renameName = ""
    @State private var renamingWorkspaceId: String?
    @State private var pendingCloseWorkspace: Workspace?
    @State private var closingWorkspaceId: String?
    @State private var workspaceActionError: String?
    var onSelect: (Workspace) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                searchBar

                VStack(alignment: .leading, spacing: 10) {
                    CmuxRule(title: "workspaces")
                    LazyVStack(spacing: 10) {
                        ForEach(filteredWorkspaces) { workspace in
                            WorkspaceCard(
                                workspace: workspace,
                                surfaceCount: store.surfaceCount(for: workspace.id),
                                unreadCount: notifStore.unreadByWorkspace[workspace.id] ?? 0,
                                isSelected: store.selectedId == workspace.id,
                                isRenaming: renamingWorkspaceId == workspace.id,
                                isClosing: closingWorkspaceId == workspace.id,
                                onRename: {
                                    renameName = workspace.name
                                    pendingRenameWorkspace = workspace
                                },
                                onClose: { pendingCloseWorkspace = workspace }
                            ) {
                                store.selectedId = workspace.id
                                onSelect(workspace)
                            }
                        }
                    }
                }

                if let workspaceActionError {
                    HStack(spacing: 8) {
                        Text("!")
                            .cmuxDisplay(11)
                        Text(workspaceActionError)
                            .cmuxMono(11)
                            .lineLimit(3)
                    }
                    .foregroundStyle(CmuxTheme.accentRed)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CmuxTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(CmuxTheme.accentRed.opacity(0.5), lineWidth: 1)
                    )
                    .accessibilityIdentifier("WorkspaceActionError")
                }

                if filteredWorkspaces.isEmpty {
                    VStack(spacing: 10) {
                        Text("[ no workspaces ]")
                            .cmuxDisplay(13)
                            .foregroundStyle(CmuxTheme.muted)
                        Text("pull to refresh; check relay connection")
                            .cmuxMono(11)
                            .foregroundStyle(CmuxTheme.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .scrollContentBackground(.hidden)
        .background(CmuxTheme.canvas)
        .alert("New Workspace", isPresented: $creating) {
            TextField("name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    if !name.isEmpty { try? await store.create(name: name) }
                    newName = ""
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Rename Workspace",
            isPresented: Binding(
                get: { pendingRenameWorkspace != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingRenameWorkspace = nil
                        renameName = ""
                    }
                }
            )
        ) {
            TextField("name", text: $renameName)
            Button("Rename") {
                guard let workspace = pendingRenameWorkspace else { return }
                let title = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
                pendingRenameWorkspace = nil
                renameName = ""
                if !title.isEmpty {
                    renameWorkspace(workspace, title: title)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRenameWorkspace = nil
                renameName = ""
            }
        }
        .confirmationDialog(
            "Close workspace?",
            isPresented: Binding(
                get: { pendingCloseWorkspace != nil },
                set: { isPresented in
                    if !isPresented { pendingCloseWorkspace = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let workspace = pendingCloseWorkspace {
                Button("Close \(workspace.name)", role: .destructive) {
                    pendingCloseWorkspace = nil
                    closeWorkspace(workspace)
                }
            }
            Button("Cancel", role: .cancel) { pendingCloseWorkspace = nil }
        } message: {
            Text("This closes the workspace in cmux.")
        }
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("cmux")
                    .cmuxDisplay(28)
                    .foregroundStyle(CmuxTheme.ink)
                Text("remote")
                    .cmuxDisplay(28)
                    .foregroundStyle(CmuxTheme.accentGreen)
                Spacer()
                IconButton(systemName: "plus") { creating = true }
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 6, height: 6)
                Text(connectionSubtitle)
                    .cmuxMono(11)
                    .foregroundStyle(CmuxTheme.muted)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Text("/")
                .cmuxDisplay(14)
                .foregroundStyle(CmuxTheme.accentGreen)
            TextField("filter…", text: $searchText)
                .cmuxMono(14)
                .foregroundStyle(CmuxTheme.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(CmuxTheme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        )
    }

    private var filteredWorkspaces: [Workspace] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.workspaces }
        return store.workspaces.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var connectionSubtitle: String {
        switch store.connection {
        case .connected:   return "relay connected"
        case .connecting:  return "connecting…"
        case .recovering:  return "retrying relay…"
        case .disconnected: return "offline"
        case .error:       return "needs attention"
        }
    }

    private var connectionColor: Color {
        switch store.connection {
        case .connected:    return CmuxTheme.accentGreen
        case .connecting, .recovering: return CmuxTheme.accentYellow
        case .disconnected: return CmuxTheme.muted
        case .error:        return CmuxTheme.accentRed
        }
    }

    private func renameWorkspace(_ workspace: Workspace, title: String) {
        guard renamingWorkspaceId == nil else { return }
        workspaceActionError = nil
        renamingWorkspaceId = workspace.id
        Task { @MainActor in
            defer { renamingWorkspaceId = nil }
            do {
                try await store.rename(workspaceId: workspace.id, title: title)
            } catch {
                workspaceActionError = String(describing: error)
            }
        }
    }

    private func closeWorkspace(_ workspace: Workspace) {
        guard closingWorkspaceId == nil else { return }
        workspaceActionError = nil
        closingWorkspaceId = workspace.id
        Task { @MainActor in
            defer { closingWorkspaceId = nil }
            do {
                try await store.close(workspaceId: workspace.id)
            } catch {
                workspaceActionError = String(describing: error)
            }
        }
    }
}

private struct WorkspaceCard: View {
    let workspace: Workspace
    let surfaceCount: Int
    let unreadCount: Int
    let isSelected: Bool
    let isRenaming: Bool
    let isClosing: Bool
    let onRename: () -> Void
    let onClose: () -> Void
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(CmuxTheme.surfaceSunken)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(isSelected ? CmuxTheme.accentGreen : CmuxTheme.divider, lineWidth: 1)
                            )
                        Text(String(format: "%02d", workspace.index + 1))
                            .cmuxDisplay(13)
                            .foregroundStyle(isSelected ? CmuxTheme.accentGreen : CmuxTheme.muted)
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(workspace.name)
                            .cmuxMono(15, weight: .medium)
                            .foregroundStyle(CmuxTheme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        HStack(spacing: 6) {
                            Text("\(surfaceCount)")
                                .cmuxDisplay(11)
                                .foregroundStyle(CmuxTheme.accentBlue)
                            Text("surfaces")
                                .cmuxMono(11)
                                .foregroundStyle(CmuxTheme.muted)
                        }
                    }

                    Spacer()

                    if unreadCount > 0 {
                        Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                            .cmuxDisplay(9)
                            .foregroundStyle(CmuxTheme.canvas)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(CmuxTheme.accentRed)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .accessibilityLabel("\(unreadCount) unread notifications")
                    }

                    if isSelected {
                        Text("→")
                            .cmuxDisplay(16)
                            .foregroundStyle(CmuxTheme.accentGreen)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("WorkspaceCard-\(workspace.id)")
            .accessibilityLabel(workspace.name)

            WorkspaceCardIconButton(
                systemName: "pencil",
                isLoading: isRenaming,
                action: onRename
            )
            .disabled(isRenaming || isClosing)
            .accessibilityLabel("Rename workspace \(workspace.name)")

            WorkspaceCardIconButton(
                systemName: "xmark",
                isLoading: isClosing,
                action: onClose
            )
            .disabled(isClosing || isRenaming)
            .accessibilityLabel("Close workspace \(workspace.name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(isSelected ? CmuxTheme.surfaceRaised : CmuxTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        )
    }
}

private struct WorkspaceCardIconButton: View {
    let systemName: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .tint(CmuxTheme.muted)
                        .scaleEffect(0.72)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(CmuxTheme.muted)
            .frame(width: 34, height: 34)
            .background(CmuxTheme.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(CmuxTheme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct IconButton: View {
    let systemName: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(CmuxTheme.ink)
                .frame(width: 36, height: 36)
                .background(CmuxTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
