import SwiftUI
import SharedKit

struct WorkspaceListView: View {
    @Bindable var store: WorkspaceStore
    @State private var creating = false
    @State private var newName = ""
    @State private var searchText = ""
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
                                isSelected: store.selectedId == workspace.id
                            ) {
                                store.selectedId = workspace.id
                                onSelect(workspace)
                            }
                        }
                    }
                }

                if filteredWorkspaces.isEmpty {
                    VStack(spacing: 10) {
                        Text("[ no workspaces ]")
                            .cmuxDisplay(13)
                            .foregroundStyle(CmuxTheme.muted)
                        Text("pull to refresh — check relay connection")
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
        case .disconnected: return "offline"
        case .error:       return "needs attention"
        }
    }

    private var connectionColor: Color {
        switch store.connection {
        case .connected:    return CmuxTheme.accentGreen
        case .connecting:   return CmuxTheme.accentYellow
        case .disconnected: return CmuxTheme.muted
        case .error:        return CmuxTheme.accentRed
        }
    }
}

private struct WorkspaceCard: View {
    let workspace: Workspace
    let surfaceCount: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
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

                if isSelected {
                    Text("→")
                        .cmuxDisplay(16)
                        .foregroundStyle(CmuxTheme.accentGreen)
                }
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
        .buttonStyle(.plain)
        .accessibilityLabel(workspace.name)
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
