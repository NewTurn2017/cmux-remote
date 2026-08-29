import SwiftUI
import UIKit
import SharedKit

struct WorkspaceView: View {
    private static let padKeyboardDeckClearance: CGFloat = 146
    private static let terminalViewportStyle: WorkspaceSurroundStyle = .terminalViewport
    private static let surroundStyle: WorkspaceSurroundStyle = .physicalBlack

    @Bindable var workspaceStore: WorkspaceStore
    @Bindable var surfaceStore: SurfaceStore
    @Bindable var notifStore: NotificationStore
    @Bindable var hostStatusStore: HostStatusStore
    @Bindable var remoteFiles: RemoteFileFeatureCoordinator
    @Binding var preferredSurfaceId: String?
    let onBack: () -> Void
    @State private var showDrawer = false
    @State private var activeWorkspaceId: String?
    @State private var activeSurfaceId: String?
    @State private var composer = CommandComposer()
    @State private var inputMode: TerminalInputMode = .command
    @State private var liveInputFocused = false
    @State private var liveInputEcho = ""
    @State private var headerHeight: CGFloat = 128
    @State private var accessoryHeight: CGFloat = 172
    @State private var keyboardHeight: CGFloat = 0
    @State private var scrollToBottomRequest = 0
    @State private var pendingCloseSurface: Surface?
    @State private var surfaceActionInFlight = false
    @State private var surfaceActionError: String?
    @AppStorage("cmux.demoMode") private var demoMode: Bool = false
    @FocusState private var commandFieldFocused: Bool

    private var attachmentStore: AttachmentStore {
        remoteFiles.attachments.store
    }

    var body: some View {
        GeometryReader { proxy in
            let accessoryLayout = WorkspaceAccessoryLayout.resolve(
                containerSize: proxy.size,
                isPad: UIDevice.current.userInterfaceIdiom == .pad
            )
            let keyboardVisible = keyboardHeight > proxy.safeAreaInsets.bottom + 20
            let keyboardControlsActive = keyboardVisible || commandFieldFocused || liveInputFocused
            let keyboardAccessoryOffset: CGFloat = keyboardControlsActive ? -112 : 0
            let padKeyboardDeckVisible = keyboardHeight > 20
                && UIDevice.current.userInterfaceIdiom == .pad
            let terminalBottomInset = max(0, accessoryHeight + keyboardAccessoryOffset + 10)
            let terminalTopInset = keyboardControlsActive
                ? proxy.safeAreaInsets.top + 20
                : proxy.safeAreaInsets.top + headerHeight + 10
            ZStack(alignment: .bottom) {
                TerminalView(
                    store: surfaceStore,
                    topContentInset: terminalTopInset,
                    bottomContentInset: terminalBottomInset,
                    scrollToBottomRequest: scrollToBottomRequest
                )
                .ignoresSafeArea(.container, edges: .all)

                VStack(spacing: 0) {
                    terminalHeader
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .background(Self.surroundStyle.color.ignoresSafeArea(edges: .top))
                        .readHeight($headerHeight)
                    Spacer()
                    terminalAccessory(layout: accessoryLayout)
                        .frame(width: max(0, proxy.size.width - 32))
                        .padding(.horizontal, 16)
                        .background(Self.surroundStyle.color.ignoresSafeArea(edges: .bottom))
                        .readHeight($accessoryHeight)
                    if padKeyboardDeckVisible {
                        Color.clear
                            .frame(height: Self.padKeyboardDeckClearance)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !attachmentStore.items.isEmpty {
                    AttachmentBatchView(store: attachmentStore)
                        .frame(width: max(0, proxy.size.width - 32))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(
                            .top,
                            accessoryLayout == .padLandscape
                                ? 100
                                : 54
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }

                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("TerminalViewportBackground")
                    .accessibilityValue(Self.terminalViewportStyle.rawValue)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)

                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("WorkspaceSurroundBackground")
                    .accessibilityValue(Self.surroundStyle.rawValue)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
            .background(Self.surroundStyle.color.ignoresSafeArea())
        }
        .sheet(isPresented: $showDrawer) {
            WorkspaceDrawer(store: workspaceStore) { workspaceId, surfaceId in
                workspaceStore.selectedId = workspaceId
                notifStore.markWorkspaceSeen(workspaceId)
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
            await hostStatusStore.refreshBattery()
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
        .onChange(of: attachmentStore.isUploading) { wasUploading, isUploading in
            guard wasUploading, !isUploading else { return }
            synchronizeAttachmentDraft(with: attachmentStore.quotedPaths)
        }
    }

    private func updateKeyboardHeight(from notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let window = windowScene.windows.first(where: { $0.isKeyWindow })
        else { return }
        let keyboardOverlap = max(0, min(window.bounds.height, frame.height))
        updateKeyboardHeight(keyboardOverlap)
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
                HeaderSquare(systemName: "chevron.left", identifier: "WorkspaceBackButton", action: onBack)

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
                    BatteryBadge(battery: hostStatusStore.battery) {
                        Task { await hostStatusStore.refreshBattery() }
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
                TerminalArtifactControlSlot(
                    remoteFiles: remoteFiles,
                    surfaceStore: surfaceStore,
                    connection: workspaceStore.connection,
                    workspaceID: activeWorkspaceId,
                    surfaceID: activeSurfaceId
                )
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
        IconKey(
            systemName: "arrow.down.to.line",
            accessibilityLabel: "Scroll terminal to bottom",
            identifier: "TerminalScrollToBottomButton",
            width: 44,
            height: 44
        ) {
            scrollToBottomRequest &+= 1
        }
    }

    private func terminalAccessory(layout: WorkspaceAccessoryLayout) -> some View {
        accessoryContent(layout: layout)
        .padding(.horizontal, layout == .padLandscape ? 8 : 12)
        .padding(.vertical, layout == .padLandscape ? 0 : 12)
        .background(CmuxTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        }
        .shadow(color: CmuxTheme.hardShadow, radius: 20, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("TerminalAccessoryPanel")
    }

    @ViewBuilder
    private func accessoryContent(layout: WorkspaceAccessoryLayout) -> some View {
        switch layout {
        case .stacked:
            VStack(spacing: 10) {
                composerInput(layout: layout)
                HStack(spacing: 4) {
                    utilityActionButtons(layout: layout)
                    attachmentActionButtons(controlSize: 44, identity: "deck")
                    scrollToBottomButton
                    submitButton(layout: layout)
                }
                inputFeedback(lineLimit: 2)
                if attachmentStore.items.isEmpty {
                    VStack(spacing: 4) {
                        primaryShortcutRow
                        secondaryShortcutRow
                    }
                }
            }
        case .padLandscape:
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    composerInput(layout: layout)
                    utilityActionButtons(layout: layout)
                    attachmentActionButtons(controlSize: 44, identity: "pad-landscape")
                    scrollToBottomButton
                    submitButton(layout: layout)
                }
                HStack(spacing: 8) {
                    allShortcutsRow
                    inputFeedback(lineLimit: 1, maxWidth: 180)
                }
            }
        }
    }

    private func composerInput(layout: WorkspaceAccessoryLayout) -> some View {
        HStack(spacing: 8) {
            Button {
                toggleInputMode()
            } label: {
                Text(inputMode.label)
                    .cmuxDisplay(10)
                    .foregroundStyle(inputMode == .live ? CmuxTheme.canvas : CmuxTheme.accentGreen)
                    .frame(
                        width: layout == .padLandscape ? 44 : 42,
                        height: layout == .padLandscape ? 44 : 26
                    )
                    .background(inputMode == .live ? CmuxTheme.accentGreen : CmuxTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("InputModeToggleButton")
            .accessibilityLabel(inputMode == .live ? "Switch to command input mode" : "Switch to live input mode")

            Text("$")
                .cmuxDisplay(14)
                .foregroundStyle(CmuxTheme.accentGreen)

            if inputMode == .command {
                ZStack(alignment: .leading) {
                    if composer.draft.isEmpty {
                        Text("type a command…")
                            .cmuxMono(14)
                            .foregroundStyle(CmuxTheme.ink.opacity(0.65))
                            .allowsHitTesting(false)
                    }

                    commandTextField(layout: layout)
                }
            } else {
                ZStack(alignment: .leading) {
                    LiveTerminalInputView(
                        displayText: liveInputEcho,
                        isFocused: $liveInputFocused,
                        onText: { text in
                            rememberLiveInputText(text)
                            sendText(text)
                        },
                        onKey: { key in
                            rememberLiveInputKey(key)
                            sendKey(key)
                        }
                    )
                    .accessibilityIdentifier("LiveInputField")
                    .accessibilityLabel("Live terminal input")

                    if liveInputEcho.isEmpty {
                        Text(String(
                            localized: "workspace.live_input.placeholder",
                            defaultValue: "Your input is sent immediately…"
                        ))
                            .cmuxMono(14)
                            .foregroundStyle(CmuxTheme.muted)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("LiveInputPlaceholder")
                    }
                }
                .frame(minHeight: 26, maxHeight: 34)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, layout == .padLandscape ? 0 : 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(CmuxTheme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(commandFieldFocused ? CmuxTheme.accentGreen : CmuxTheme.divider, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func commandTextField(layout: WorkspaceAccessoryLayout) -> some View {
        if layout == .padLandscape {
            CommandTextFieldView(
                text: $composer.draft,
                isFocused: commandFieldFocused,
                isEnabled: !composer.isSending,
                onFocusChange: { commandFieldFocused = $0 },
                onSubmit: { submitCommand() }
            )
                .frame(height: 44)
        } else {
            TextField("", text: $composer.draft, axis: .vertical)
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
                .background(CommandInputTraitsConfigurator())
                .accessibilityIdentifier("CommandComposerField")
                .accessibilityLabel("Command input")
        }
    }

    private func utilityActionButtons(layout: WorkspaceAccessoryLayout) -> some View {
        let controlSize: CGFloat = 44
        let controlHeight: CGFloat = 44
        return HStack(spacing: layout == .padLandscape ? 8 : 4) {
            IconKey(systemName: "keyboard.chevron.compact.down",
                    accessibilityLabel: "Dismiss keyboard",
                    identifier: "CommandKeyboardDismissButton",
                    width: controlSize,
                    height: controlHeight) { dismissKeyboard() }
            IconKey(systemName: "delete.left",
                    accessibilityLabel: "Send terminal backspace",
                    identifier: "CommandBackspaceButton",
                    width: controlSize,
                    height: controlHeight) { sendKey(.backspace) }
            IconKey(systemName: "doc.on.clipboard",
                    accessibilityLabel: "Paste clipboard into command field",
                    identifier: "CommandPasteButton",
                    width: controlSize,
                    height: controlHeight) { pasteClipboard() }
        }
    }

    private func attachmentActionButtons(
        controlSize: CGFloat,
        identity: String,
        usesPadKeyboardStyle: Bool = false
    ) -> some View {
        WorkspaceAttachmentControls(
            coordinator: remoteFiles.attachments,
            hostGeneration: remoteFiles.hostGeneration,
            isEnabled: remoteFiles.capabilities.supportsChunkUploadV2,
            controlSize: controlSize,
            identity: identity,
            usesPadKeyboardStyle: usesPadKeyboardStyle,
            onStart: { composer.clearError() },
            onPathsChanged: synchronizeAttachmentDraft(with:),
            onImportFailure: { composer.errorMessage = $0 },
            onPhotoFailure: { composer.failSubmit($0) },
            onPhotoCompleted: { commandFieldFocused = true }
        )
    }

    private func submitButton(layout: WorkspaceAccessoryLayout) -> some View {
        Button { submitCommand() } label: {
            Group {
                if composer.isSending {
                    ProgressView()
                        .tint(CmuxTheme.canvas)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "return")
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .foregroundStyle(CmuxTheme.canvas)
            .frame(width: 44, height: 44)
            .background(composer.isSending ? CmuxTheme.muted : CmuxTheme.accentGreen)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(composer.isSending)
        .accessibilityIdentifier("CommandSubmitButton")
        .accessibilityLabel("Send terminal input")
    }

    @ViewBuilder
    private func inputFeedback(lineLimit: Int, maxWidth: CGFloat? = .infinity) -> some View {
        if let message = inputFeedbackMessage {
            HStack(spacing: 6) {
                Text(inputFeedbackIsError ? "!" : "›")
                    .cmuxDisplay(11)
                Text(message)
                    .cmuxMono(11)
                    .lineLimit(lineLimit)
            }
            .foregroundStyle(inputFeedbackIsError ? CmuxTheme.accentRed : CmuxTheme.accentGreen)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
            .accessibilityIdentifier("InputStatusMessage")
        }
    }

    private var primaryShortcutRow: some View {
        HStack(spacing: 4) {
            KeyButton(label: "esc") { sendKey(.esc) }
            KeyButton(label: "^C", accessibilityLabel: "send ctrl c") {
                sendKey(.named("c", modifiers: [.ctrl]))
            }
            KeyButton(label: "tab") { sendKey(.tab) }
            KeyButton(label: "←", accessibilityLabel: "send left arrow") { sendKey(.left) }
            KeyButton(label: "↑", accessibilityLabel: "send up arrow") { sendKey(.up) }
            KeyButton(label: "↓", accessibilityLabel: "send down arrow") { sendKey(.down) }
            KeyButton(label: "→", accessibilityLabel: "send right arrow") { sendKey(.right) }
        }
    }

    private var secondaryShortcutRow: some View {
        HStack(spacing: 4) {
            KeyButton(label: "OK", accessibilityLabel: "send OK and enter") { sendOK() }
            KeyButton(label: "/") { sendSymbol("/") }
            KeyButton(label: "$") { sendSymbol("$") }
            KeyButton(label: "/new", accessibilityLabel: "send slash new shortcut") { sendText("/new") }
            KeyButton(label: "space", accessibilityLabel: "send space for omx selection") { sendText(" ") }
        }
    }

    private var allShortcutsRow: some View {
        HStack(spacing: 4) {
            KeyButton(label: "esc", minimumHeight: 44) { sendKey(.esc) }
            KeyButton(label: "^C", accessibilityLabel: "send ctrl c", minimumHeight: 44) {
                sendKey(.named("c", modifiers: [.ctrl]))
            }
            KeyButton(label: "tab", minimumHeight: 44) { sendKey(.tab) }
            KeyButton(label: "←", accessibilityLabel: "send left arrow", minimumHeight: 44) { sendKey(.left) }
            KeyButton(label: "↑", accessibilityLabel: "send up arrow", minimumHeight: 44) { sendKey(.up) }
            KeyButton(label: "↓", accessibilityLabel: "send down arrow", minimumHeight: 44) { sendKey(.down) }
            KeyButton(label: "→", accessibilityLabel: "send right arrow", minimumHeight: 44) { sendKey(.right) }
            KeyButton(label: "OK", accessibilityLabel: "send OK and enter", minimumHeight: 44) { sendOK() }
            KeyButton(label: "/", minimumHeight: 44) { sendSymbol("/") }
            KeyButton(label: "$", minimumHeight: 44) { sendSymbol("$") }
            KeyButton(label: "/new", accessibilityLabel: "send slash new shortcut", minimumHeight: 44) { sendText("/new") }
            KeyButton(label: "space", accessibilityLabel: "send space for omx selection", minimumHeight: 44) { sendText(" ") }
        }
    }

    private func dismissKeyboard() {
        commandFieldFocused = false
        liveInputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func toggleInputMode() {
        switch inputMode {
        case .command:
            inputMode = .live
            composer.draft = ""
            liveInputEcho = ""
            commandFieldFocused = false
            liveInputFocused = true
        case .live:
            inputMode = .command
            liveInputEcho = ""
            liveInputFocused = false
            commandFieldFocused = true
        }
    }

    private func pasteClipboard() {
        composer.paste(UIPasteboard.general.string)
        commandFieldFocused = true
    }

    private func submitCommand() {
        if composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dismissKeyboard()
            Task {
                do {
                    let (workspaceId, surfaceId) = try activeSurface()
                    try await surfaceStore.sendKey(workspaceId: workspaceId, surfaceId: surfaceId, key: .enter)
                    await MainActor.run {
                        composer.clearError()
                        dismissKeyboard()
                    }
                } catch {
                    await MainActor.run { composer.failSubmit(error) }
                }
            }
            return
        }
        guard let command = composer.beginSubmit() else { return }
        dismissKeyboard()
        Task {
            do {
                let (workspaceId, surfaceId) = try activeSurface()
                try await surfaceStore.submitCommand(workspaceId: workspaceId, surfaceId: surfaceId, command: command)
                await MainActor.run {
                    composer.completeSubmit(command)
                    dismissKeyboard()
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

    private func rememberLiveInputText(_ text: String) {
        guard inputMode == .live, !text.isEmpty else { return }
        let visible = text.replacingOccurrences(of: " ", with: "␠")
        liveInputEcho = String((liveInputEcho + visible).suffix(48))
    }

    private func rememberLiveInputKey(_ key: Key) {
        guard inputMode == .live else { return }
        switch key {
        case .backspace:
            if !liveInputEcho.isEmpty {
                liveInputEcho.removeLast()
            } else {
                liveInputEcho = "⌫"
            }
        case .enter:
            liveInputEcho = "↵"
        case .tab:
            liveInputEcho = String((liveInputEcho + "⇥").suffix(48))
        case .esc:
            liveInputEcho = "esc"
        default:
            liveInputEcho = KeyEncoder.encode(key)
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

    private func synchronizeAttachmentDraft(with paths: [String]) {
        guard let draft = remoteFiles.attachments.mergedDraft(
            currentDraft: composer.draft,
            quotedPaths: paths
        ) else { return }
        composer.draft = draft
        composer.clearError()
        commandFieldFocused = true
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

private enum WorkspaceSurroundStyle: String {
    case terminalViewport = "tokyo-night-terminal-16161e"
    case physicalBlack = "physical-black"

    var color: Color {
        switch self {
        case .terminalViewport: CmuxTheme.terminal
        case .physicalBlack: .black
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

enum WorkspaceAccessoryLayout: Equatable {
    case stacked
    case padLandscape

    static func resolve(containerSize: CGSize, isPad: Bool) -> Self {
        guard isPad, containerSize.width >= 700, containerSize.width > containerSize.height else {
            return .stacked
        }
        return .padLandscape
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
    var identifier: String? = nil
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
        .accessibilityIdentifier(identifier ?? "")
    }
}

private struct BatteryBadge: View {
    let battery: HostBatteryState
    let refresh: () -> Void

    var body: some View {
        Button(action: refresh) {
            HStack(spacing: 4) {
                Image(systemName: batteryIcon)
                    .font(.system(size: 10, weight: .bold))
                Text(battery.displayText)
                    .cmuxDisplay(9)
            }
            .foregroundStyle(battery.available ? CmuxTheme.accentGreen : CmuxTheme.muted)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(CmuxTheme.surfaceRaised.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(CmuxTheme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("HostBatteryBadge")
        .accessibilityLabel(battery.accessibilityText)
    }

    private var batteryIcon: String {
        if battery.isCharging == true { return "battery.100.bolt" }
        guard let percent = battery.percent else { return "battery.0" }
        switch percent {
        case 75...100: return "battery.100"
        case 35..<75: return "battery.50"
        default: return "battery.25"
        }
    }
}

private struct IconKey: View {
    let systemName: String
    var accessibilityLabel: String? = nil
    var identifier: String? = nil
    var width: CGFloat = 40
    var height: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CmuxTheme.ink)
                .frame(width: width, height: height)
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
    var minimumHeight: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .cmuxDisplay(12)
                .multilineTextAlignment(.center)
                .foregroundStyle(isActive ? CmuxTheme.accentGreen : CmuxTheme.ink)
                .frame(maxWidth: .infinity, minHeight: minimumHeight)
                .background(isActive ? CmuxTheme.surfaceRaised : CmuxTheme.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isActive ? CmuxTheme.accentGreen : CmuxTheme.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? label.replacingOccurrences(of: "\n", with: " "))
        .accessibilityIdentifier(accessibilityLabel ?? label.replacingOccurrences(of: "\n", with: " "))
    }
}

private enum TerminalInputMode: Equatable {
    case command
    case live

    var label: String {
        switch self {
        case .command: return "CMD"
        case .live: return "LIVE"
        }
    }
}

private struct CommandInputTraitsConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> CommandInputTraitsView {
        let view = CommandInputTraitsView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: CommandInputTraitsView, context: Context) {
        uiView.disableSmartPunctuation()
    }
}

private struct CommandTextFieldView: UIViewRepresentable {
    @Binding var text: String
    var isFocused: Bool
    var isEnabled: Bool
    var onFocusChange: (Bool) -> Void
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let view = UITextField()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = UIColor(CmuxTheme.ink)
        view.tintColor = UIColor(CmuxTheme.accentGreen)
        let baseFont = UIFont(name: "GeistMono-Regular", size: 14)
            ?? UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.returnKeyType = .send
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "CommandComposerField"
        view.accessibilityLabel = "Command input"
        view.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        return view
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        if let pendingText = context.coordinator.pendingUIKitText,
           uiView.text == pendingText {
            if text == pendingText {
                context.coordinator.pendingUIKitText = nil
            }
        } else if uiView.text != text {
            uiView.text = text
        }
        uiView.isEnabled = isEnabled
        if isFocused, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CommandTextFieldView
        var pendingUIKitText: String?

        init(parent: CommandTextFieldView) {
            self.parent = parent
        }

        @objc func textChanged(_ textField: UITextField) {
            let updatedText = textField.text ?? ""
            pendingUIKitText = updatedText
            parent.text = updatedText
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onFocusChange(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.onFocusChange(false)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

private final class CommandInputTraitsView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        disableSmartPunctuation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        disableSmartPunctuation()
    }

    func disableSmartPunctuation() {
        var ancestor = superview
        while let view = ancestor {
            if configureTextInput(in: view) {
                return
            }
            ancestor = view.superview
        }
    }

    private func configureTextInput(in view: UIView) -> Bool {
        guard view !== self else { return false }
        if let textField = view as? UITextField {
            textField.smartDashesType = .no
            textField.smartQuotesType = .no
            return true
        }
        if let textView = view as? UITextView {
            textView.smartDashesType = .no
            textView.smartQuotesType = .no
            return true
        }
        for subview in view.subviews where configureTextInput(in: subview) {
            return true
        }
        return false
    }
}

private struct LiveTerminalInputView: UIViewRepresentable {
    var displayText: String
    @Binding var isFocused: Bool
    var onText: (String) -> Void
    var onKey: (Key) -> Void

    func makeUIView(context: Context) -> LiveTerminalTextView {
        let view = LiveTerminalTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = UIColor(CmuxTheme.ink)
        view.tintColor = UIColor(CmuxTheme.accentGreen)
        view.font = UIFont(name: "GeistMono-Regular", size: 14) ?? UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .default
        view.returnKeyType = .default
        view.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.accessibilityIdentifier = "LiveInputField"
        view.accessibilityLabel = "Live terminal input"
        return view
    }

    func updateUIView(_ uiView: LiveTerminalTextView, context: Context) {
        context.coordinator.parent = self
        uiView.accessibilityIdentifier = "LiveInputField"
        uiView.accessibilityLabel = "Live terminal input"
        let currentText = uiView.text ?? ""
        let hasLocalHangulInput = LiveTerminalInputTranslator.containsHangul(currentText)
        uiView.accessibilityValue = hasLocalHangulInput ? currentText : displayText
        if !hasLocalHangulInput, uiView.text != displayText {
            uiView.text = displayText
        }
        if !hasLocalHangulInput {
            uiView.selectedRange = NSRange(location: (uiView.text as NSString).length, length: 0)
        }
        uiView.onDeleteWhenEmpty = { [weak coordinator = context.coordinator] in
            coordinator?.handle(actions: LiveTerminalInputTranslator.interpretDeletion())
        }
        if isFocused, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LiveTerminalInputView

        init(parent: LiveTerminalInputView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if LiveTerminalInputTranslator.shouldUseLocalEditing(
                currentText: textView.text ?? "",
                replacementText: text
            ) {
                return true
            }
            if text.isEmpty, range.length > 0 {
                handle(actions: LiveTerminalInputTranslator.interpretDeletion(count: range.length))
            } else {
                handle(actions: LiveTerminalInputTranslator.interpret(replacementText: text))
            }
            return false
        }

        func handle(actions: [LiveTerminalInputAction]) {
            for action in actions {
                switch action {
                case .text(let text): parent.onText(text)
                case .key(let key): parent.onKey(key)
                }
            }
        }
    }
}

private final class LiveTerminalTextView: UITextView {
    var onDeleteWhenEmpty: (() -> Void)?

    override func deleteBackward() {
        if text.isEmpty {
            onDeleteWhenEmpty?()
        } else {
            super.deleteBackward()
        }
    }
}
