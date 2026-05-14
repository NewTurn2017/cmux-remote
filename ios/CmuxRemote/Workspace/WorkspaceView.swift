import SwiftUI
import UIKit
import SharedKit

struct WorkspaceView: View {
    @Bindable var workspaceStore: WorkspaceStore
    @Bindable var surfaceStore: SurfaceStore
    @Binding var preferredSurfaceId: String?
    let onBack: () -> Void
    @State private var showDrawer = false
    @State private var activeWorkspaceId: String?
    @State private var activeSurfaceId: String?
    @State private var composer = CommandComposer()
    @State private var headerHeight: CGFloat = 128
    @State private var accessoryHeight: CGFloat = 172
    @State private var keyboardHeight: CGFloat = 0
    @State private var scrollToBottomRequest = 0
    @State private var pendingCloseSurface: Surface?
    @State private var surfaceActionInFlight = false
    @State private var surfaceActionError: String?
    @State private var mouseMode = false
    @AppStorage("cmux.demoMode") private var demoMode: Bool = false
    @FocusState private var commandFieldFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let keyboardVisible = keyboardHeight > proxy.safeAreaInsets.bottom + 20
            let keyboardControlsActive = keyboardVisible || commandFieldFocused
            let keyboardAccessoryOffset: CGFloat = keyboardControlsActive ? -112 : 0
            let bottomObstruction = keyboardVisible ? 0 : proxy.safeAreaInsets.bottom
            let accessoryBottomPadding = bottomObstruction + keyboardAccessoryOffset + 12
            let terminalBottomInset = max(0, accessoryHeight + keyboardAccessoryOffset + 10)
            let terminalTopInset = keyboardControlsActive
                ? proxy.safeAreaInsets.top + 20
                : proxy.safeAreaInsets.top + headerHeight + 10
            ZStack(alignment: .bottom) {
                TerminalView(
                    store: surfaceStore,
                    topContentInset: terminalTopInset,
                    bottomContentInset: terminalBottomInset,
                    scrollToBottomRequest: scrollToBottomRequest,
                    mouseMode: mouseMode,
                    onMouseClick: { col, row in sendMouseClick(col: col, row: row) }
                )
                .ignoresSafeArea(.container, edges: .all)

                VStack(spacing: 0) {
                    terminalHeader
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .readHeight($headerHeight)
                    Spacer()
                    terminalAccessory
                        .padding(.horizontal, 16)
                        .padding(.bottom, accessoryBottomPadding)
                        .readHeight($accessoryHeight)
                }

                scrollToBottomButton
                    .padding(.trailing, 24)
                    .padding(.bottom, bottomObstruction + keyboardAccessoryOffset + accessoryHeight + 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .background(CmuxTheme.terminal.ignoresSafeArea())
        }
        .sheet(isPresented: $showDrawer) {
            WorkspaceDrawer(store: workspaceStore) { workspaceId, surfaceId in
                workspaceStore.selectedId = workspaceId
                activeWorkspaceId = workspaceId
                activeSurfaceId = surfaceId
                surfaceActionError = nil
                showDrawer = false
                Task { await subscribeAndPinToBottom(workspaceId: workspaceId, surfaceId: surfaceId) }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Close surface?",
            isPresented: Binding(
                get: { pendingCloseSurface != nil },
                set: { isPresented in
                    if !isPresented { pendingCloseSurface = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let surface = pendingCloseSurface {
                Button("Close \(surface.title)", role: .destructive) {
                    pendingCloseSurface = nil
                    closeSurface(surface)
                }
            }
            Button("Cancel", role: .cancel) { pendingCloseSurface = nil }
        } message: {
            Text("This closes the terminal surface in cmux.")
        }
        .task {
            await subscribeFirstSurfaceIfNeeded()
            await consumePreferredSurfaceIfNeeded()
        }
        .onChange(of: workspaceStore.selectedId) { _, newValue in
            Task {
                await switchWorkspace(to: newValue)
                await consumePreferredSurfaceIfNeeded()
            }
        }
        .onChange(of: preferredSurfaceId) { _, _ in
            Task { await consumePreferredSurfaceIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            updateKeyboardHeight(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { notification in
            updateKeyboardHeight(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            updateKeyboardHeight(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { notification in
            updateKeyboardHeight(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
    }

    private func updateKeyboardHeight(from notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let screenHeight = UIScreen.main.bounds.height
        updateKeyboardHeight(max(0, screenHeight - frame.minY))
    }

    private func updateKeyboardHeight(_ nextHeight: CGFloat) {
        let screenHeight = UIScreen.main.bounds.height
        let clampedHeight = min(max(0, nextHeight), screenHeight * 0.58)
        guard abs(keyboardHeight - clampedHeight) > 0.5 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            keyboardHeight = clampedHeight
        }
    }

    private var terminalHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HeaderSquare(systemName: "chevron.left", action: onBack)

                HStack(spacing: 8) {
                    Text("●")
                        .cmuxDisplay(11)
                        .foregroundStyle(demoMode ? CmuxTheme.accentYellow : CmuxTheme.accentGreen)
                    Text(currentWorkspace?.name ?? "no workspace")
                        .cmuxMono(13, weight: .medium)
                        .foregroundStyle(CmuxTheme.ink)
                        .lineLimit(1)
                    if demoMode {
                        Text("DEMO")
                            .cmuxDisplay(9)
                            .foregroundStyle(CmuxTheme.canvas)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(CmuxTheme.accentYellow)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .accessibilityLabel("Demo mode active")
                    }
                    Spacer()
                    Text("×")
                        .cmuxDisplay(16)
                        .foregroundStyle(CmuxTheme.muted)
                        .onTapGesture { onBack() }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(CmuxTheme.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                )

                HeaderSquare(systemName: "square.grid.2x2") { showDrawer = true }
            }

            if !commandFieldFocused, keyboardHeight <= 20, let workspace = currentWorkspace {
                let surfaces = workspaceStore.surfaces(for: workspace.id)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(surfaces) { surface in
                            SurfaceChip(
                                title: surface.title,
                                isSelected: activeSurfaceId == surface.id,
                                canClose: surfaces.count > 1,
                                isBusy: surfaceActionInFlight,
                                onSelect: { selectSurface(surface, in: workspace) },
                                onClose: { pendingCloseSurface = surface }
                            )
                        }

                        NewSurfaceChip(isBusy: surfaceActionInFlight) {
                            createSurface(in: workspace)
                        }
                    }
                }

                if let surfaceActionError {
                    HStack(spacing: 6) {
                        Text("!")
                            .cmuxDisplay(11)
                        Text(surfaceActionError)
                            .cmuxMono(11)
                            .lineLimit(2)
                    }
                    .foregroundStyle(CmuxTheme.accentRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("SurfaceActionError")
                }
            }
        }
    }

    private var scrollToBottomButton: some View {
        Button {
            scrollToBottomRequest &+= 1
        } label: {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(CmuxTheme.ink)
                .frame(width: 40, height: 40)
                .background(CmuxTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                )
                .shadow(color: CmuxTheme.hardShadow, radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("TerminalScrollToBottomButton")
        .accessibilityLabel("Scroll terminal to bottom")
    }

    private var terminalAccessory: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("$")
                    .cmuxDisplay(14)
                    .foregroundStyle(CmuxTheme.accentGreen)
                TextField("type a command…", text: $composer.draft, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($commandFieldFocused)
                    .cmuxMono(14)
                    .foregroundStyle(CmuxTheme.ink)
                    .submitLabel(.send)
                    .lineLimit(1...3)
                    .disabled(composer.isSending)
                    .onSubmit { submitCommand() }
                    .onTapGesture { commandFieldFocused = true }
                    .accessibilityIdentifier("CommandComposerField")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(CmuxTheme.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(commandFieldFocused ? CmuxTheme.accentGreen : CmuxTheme.divider, lineWidth: 1)
            )

            HStack(spacing: 8) {
                IconKey(systemName: "keyboard.chevron.compact.down",
                        accessibilityLabel: "Dismiss keyboard",
                        identifier: "CommandKeyboardDismissButton") { dismissKeyboard() }

                IconKey(systemName: "delete.left",
                        accessibilityLabel: "Send terminal backspace",
                        identifier: "CommandBackspaceButton") { sendKey(.backspace) }

                Spacer(minLength: 4)

                Button { submitCommand() } label: {
                    HStack(spacing: 6) {
                        if composer.isSending {
                            ProgressView().tint(CmuxTheme.canvas).scaleEffect(0.7)
                        } else {
                            Text("[ ENTER ]")
                                .cmuxDisplay(12)
                        }
                    }
                    .foregroundStyle(CmuxTheme.canvas)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(composer.isSending ? CmuxTheme.muted : CmuxTheme.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(composer.isSending)
                .accessibilityIdentifier("CommandSubmitButton")
                .accessibilityLabel("Send terminal input")
            }

            if let message = inputFeedbackMessage {
                HStack(spacing: 6) {
                    Text(inputFeedbackIsError ? "!" : "›")
                        .cmuxDisplay(11)
                    Text(message)
                        .cmuxMono(11)
                        .lineLimit(2)
                }
                .foregroundStyle(inputFeedbackIsError ? CmuxTheme.accentRed : CmuxTheme.accentGreen)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(message)
                .accessibilityIdentifier("InputStatusMessage")
            }

            HStack(spacing: 4) {
                KeyButton(label: "esc") { sendKey(.esc) }
                KeyButton(label: "OK", accessibilityLabel: "send OK and enter") { sendOK() }
                KeyButton(label: "/") { sendSymbol("/") }
                KeyButton(label: "$") { sendSymbol("$") }
                KeyButton(label: "tab") { sendKey(.tab) }
                KeyButton(label: "←", accessibilityLabel: "send left arrow") { sendKey(.left) }
                KeyButton(label: "↑", accessibilityLabel: "send up arrow") { sendKey(.up) }
                KeyButton(label: "↓", accessibilityLabel: "send down arrow") { sendKey(.down) }
                KeyButton(label: "→", accessibilityLabel: "send right arrow") { sendKey(.right) }
                KeyButton(
                    label: mouseMode ? "ms✓" : "ms",
                    accessibilityLabel: mouseMode ? "disable mouse passthrough" : "enable mouse passthrough"
                ) {
                    mouseMode.toggle()
                }
                KeyButton(label: "↺p", accessibilityLabel: "toggle previous cmux pane") {
                    togglePreviousPane()
                }
            }
        }
        .padding(12)
        .background(CmuxTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        }
        .shadow(color: CmuxTheme.hardShadow, radius: 20, x: 0, y: 10)
    }

    private func dismissKeyboard() {
        commandFieldFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func submitCommand() {
        if composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sendKey(.enter)
            return
        }
        guard let command = composer.beginSubmit() else { return }
        Task {
            do {
                let (workspaceId, surfaceId) = try activeSurface()
                try await surfaceStore.submitCommand(workspaceId: workspaceId, surfaceId: surfaceId, command: command)
                await MainActor.run {
                    composer.completeSubmit(command)
                    commandFieldFocused = true
                }
            } catch {
                await MainActor.run { composer.failSubmit(error) }
            }
        }
    }

    private func sendSymbol(_ symbol: String) {
        if composer.activeModifiers.isEmpty {
            sendText(symbol)
        } else {
            sendKey(composer.key(symbol))
        }
    }

    private func sendText(_ text: String) {
        Task {
            do {
                let (workspaceId, surfaceId) = try activeSurface()
                try await surfaceStore.sendText(workspaceId: workspaceId, surfaceId: surfaceId, text: text)
                await MainActor.run {
                    composer.clearError()
                }
            } catch {
                await MainActor.run { composer.failSubmit(error) }
            }
        }
    }

    private func sendKey(_ key: Key) {
        Task {
            do {
                let (workspaceId, surfaceId) = try activeSurface()
                try await surfaceStore.sendKey(workspaceId: workspaceId, surfaceId: surfaceId, key: key)
                await MainActor.run {
                    composer.clearError()
                }
            } catch {
                await MainActor.run { composer.failSubmit(error) }
            }
        }
    }

    private func sendMouseClick(col: Int, row: Int) {
        Task {
            do {
                try await surfaceStore.sendMouseClick(col: col, row: row)
                await MainActor.run { composer.clearError() }
            } catch {
                await MainActor.run { composer.failSubmit(error) }
            }
        }
    }

    private func togglePreviousPane() {
        Task {
            do {
                try await surfaceStore.cycleNextPane()
                await MainActor.run { composer.clearError() }
            } catch {
                await MainActor.run { composer.failSubmit(error) }
            }
        }
    }

    private func sendOK() {
        Task {
            do {
                let (workspaceId, surfaceId) = try activeSurface()
                try await surfaceStore.sendText(workspaceId: workspaceId, surfaceId: surfaceId, text: "OK")
                try await surfaceStore.sendKey(workspaceId: workspaceId, surfaceId: surfaceId, key: .enter)
                await MainActor.run { composer.clearError() }
            } catch {
                await MainActor.run { composer.failSubmit(error) }
            }
        }
    }


    private func selectSurface(_ surface: Surface, in workspace: Workspace) {
        surfaceActionError = nil
        activeWorkspaceId = workspace.id
        activeSurfaceId = surface.id
        Task { await subscribeAndPinToBottom(workspaceId: workspace.id, surfaceId: surface.id) }
    }

    private func createSurface(in workspace: Workspace) {
        guard !surfaceActionInFlight else { return }
        surfaceActionError = nil
        surfaceActionInFlight = true
        Task { @MainActor in
            defer { surfaceActionInFlight = false }
            do {
                let surface = try await workspaceStore.createSurface(workspaceId: workspace.id)
                workspaceStore.selectedId = workspace.id
                activeWorkspaceId = workspace.id
                activeSurfaceId = surface.id
                preferredSurfaceId = nil
                await subscribeAndPinToBottom(workspaceId: workspace.id, surfaceId: surface.id)
            } catch {
                surfaceActionError = String(describing: error)
            }
        }
    }

    private func closeSurface(_ surface: Surface) {
        guard !surfaceActionInFlight, let workspace = currentWorkspace else { return }
        let surfaces = workspaceStore.surfaces(for: workspace.id)
        guard surfaces.count > 1 else {
            surfaceActionError = "Cannot close the last surface."
            return
        }

        let closingActiveSurface = activeWorkspaceId == workspace.id && activeSurfaceId == surface.id
        let fallback = fallbackSurface(afterClosing: surface.id, in: surfaces)
        surfaceActionError = nil
        surfaceActionInFlight = true

        Task { @MainActor in
            defer { surfaceActionInFlight = false }
            do {
                try await workspaceStore.closeSurface(workspaceId: workspace.id, surfaceId: surface.id)

                if surfaceStore.subscribed == surface.id {
                    await surfaceStore.unsubscribe(surfaceId: surface.id)
                }

                if closingActiveSurface {
                    let refreshedSurfaces = workspaceStore.surfaces(for: workspace.id)
                    let nextSurface = fallback.flatMap { fallback in
                        refreshedSurfaces.first { $0.id == fallback.id }
                    } ?? refreshedSurfaces.first

                    if let nextSurface {
                        activeWorkspaceId = workspace.id
                        activeSurfaceId = nextSurface.id
                        preferredSurfaceId = nil
                        await subscribeAndPinToBottom(workspaceId: workspace.id, surfaceId: nextSurface.id)
                    } else {
                        activeSurfaceId = nil
                    }
                }
            } catch {
                surfaceActionError = String(describing: error)
            }
        }
    }

    private func fallbackSurface(afterClosing surfaceId: String, in surfaces: [Surface]) -> Surface? {
        guard let index = surfaces.firstIndex(where: { $0.id == surfaceId }) else {
            return surfaces.first(where: { $0.id != surfaceId })
        }
        let fallbackIndex = index < surfaces.count - 1 ? index + 1 : index - 1
        guard surfaces.indices.contains(fallbackIndex) else { return nil }
        let candidate = surfaces[fallbackIndex]
        return candidate.id == surfaceId ? surfaces.first(where: { $0.id != surfaceId }) : candidate
    }

    private var inputFeedbackMessage: String? {
        composer.errorMessage ?? surfaceStore.inputStatus.message
    }

    private var inputFeedbackIsError: Bool {
        composer.errorMessage != nil || surfaceStore.inputStatus.isError
    }

    private func activeSurface() throws -> (workspaceId: String, surfaceId: String) {
        guard let workspaceId = activeWorkspaceId, let surfaceId = activeSurfaceId else {
            throw TerminalInputError.noActiveSurface
        }
        return (workspaceId, surfaceId)
    }

    private var currentWorkspace: Workspace? {
        guard let id = workspaceStore.selectedId else { return nil }
        return workspaceStore.workspaces.first { $0.id == id }
    }

    private func switchWorkspace(to workspaceId: String?) async {
        if let current = activeSurfaceId { await surfaceStore.unsubscribe(surfaceId: current) }
        activeWorkspaceId = workspaceId
        activeSurfaceId = nil
        await subscribeFirstSurfaceIfNeeded()
    }

    private func subscribeFirstSurfaceIfNeeded() async {
        guard let workspace = currentWorkspace else { return }
        if activeWorkspaceId == workspace.id, activeSurfaceId != nil { return }
        let surfaces = workspaceStore.surfaces(for: workspace.id)
        guard let first = surfaces.first else { return }
        activeWorkspaceId = workspace.id
        activeSurfaceId = first.id
        await subscribeAndPinToBottom(workspaceId: workspace.id, surfaceId: first.id)
    }

    private func consumePreferredSurfaceIfNeeded() async {
        guard let workspace = currentWorkspace, let surfaceId = preferredSurfaceId else { return }
        let surfaces = workspaceStore.surfaces(for: workspace.id)
        guard surfaces.contains(where: { $0.id == surfaceId }) else {
            preferredSurfaceId = nil
            return
        }
        if activeWorkspaceId == workspace.id, activeSurfaceId == surfaceId {
            preferredSurfaceId = nil
            return
        }
        if let current = activeSurfaceId { await surfaceStore.unsubscribe(surfaceId: current) }
        activeWorkspaceId = workspace.id
        activeSurfaceId = surfaceId
        preferredSurfaceId = nil
        await subscribeAndPinToBottom(workspaceId: workspace.id, surfaceId: surfaceId)
    }

    private func subscribeAndPinToBottom(workspaceId: String, surfaceId: String) async {
        await surfaceStore.subscribe(workspaceId: workspaceId, surfaceId: surfaceId)
        scrollToBottomRequest &+= 1
    }
}

private extension View {
    func readHeight(_ height: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { height.wrappedValue = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newValue in
                        guard newValue > 0, abs(height.wrappedValue - newValue) > 0.5 else { return }
                        height.wrappedValue = newValue
                    }
            }
        }
    }
}

private enum TerminalInputError: Error, CustomStringConvertible {
    case noActiveSurface

    var description: String {
        switch self {
        case .noActiveSurface: return "Select a workspace surface before sending input."
        }
    }
}

private struct SurfaceChip: View {
    let title: String
    let isSelected: Bool
    let canClose: Bool
    let isBusy: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                Text(title)
                    .cmuxMono(11, weight: isSelected ? .medium : .regular)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? CmuxTheme.accentGreen : CmuxTheme.muted)
                    .padding(.leading, 10)
                    .padding(.trailing, canClose ? 6 : 10)
                    .frame(height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isSelected ? CmuxTheme.accentGreen : CmuxTheme.muted)
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityLabel("Close surface \(title)")
            }
        }
        .background(isSelected ? CmuxTheme.surfaceRaised : CmuxTheme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(isSelected ? CmuxTheme.accentGreen : CmuxTheme.divider, lineWidth: 1)
        )
        .opacity(isBusy && !isSelected ? 0.72 : 1)
    }
}

private struct NewSurfaceChip: View {
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView()
                        .tint(CmuxTheme.accentGreen)
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                }
                Text("new")
                    .cmuxDisplay(10)
            }
            .foregroundStyle(CmuxTheme.accentGreen)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(CmuxTheme.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(CmuxTheme.accentGreen.opacity(0.75), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityIdentifier("NewSurfaceButton")
        .accessibilityLabel("New surface")
    }
}
private struct HeaderSquare: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(CmuxTheme.ink)
                .frame(width: 40, height: 40)
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

private struct IconKey: View {
    let systemName: String
    var accessibilityLabel: String? = nil
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CmuxTheme.ink)
                .frame(width: 40, height: 36)
                .background(CmuxTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? systemName)
        .accessibilityIdentifier(identifier ?? "")
    }
}

private struct KeyButton: View {
    let label: String
    var accessibilityLabel: String?
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .cmuxDisplay(12)
                .multilineTextAlignment(.center)
                .foregroundStyle(isActive ? CmuxTheme.accentGreen : CmuxTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(isActive ? CmuxTheme.surfaceRaised : CmuxTheme.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isActive ? CmuxTheme.accentGreen : CmuxTheme.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? label.replacingOccurrences(of: "\n", with: " "))
    }
}
