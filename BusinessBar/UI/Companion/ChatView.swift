import BusinessBarCore
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ChatView

/// Streaming chat UI hosted in the companion panel. Assistant messages
/// render as markdown (headings, code blocks, links, images); user prompts
/// render verbatim so what was asked is always readable.
struct ChatView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var commandTools: CommandToolController
    let clientProvider: () -> LLMClient?

    @State private var draft: String = ""
    @State private var showHistory = false
    @State private var confirmingDeleteAll = false
    @State private var selectedProfileID: UUID?
    @State private var selectedEffort: String
    /// Tall layout for the composer, restored across restarts.
    @State private var inputExpanded: Bool
    /// Panel height from the background geometry reader; the tall input
    /// scales its cap with the window instead of a fixed line count.
    @State private var panelHeight: CGFloat = 0
    /// Base64 data URIs staged for the next message. Populated from the
    /// paperclip picker, drops, or pastes; cleared on send.
    @State private var pendingImages: [String] = []
    /// True from the send button press until the stream starts (or fails
    /// to start). Covers the server warm-up window where nothing else in
    /// the panel moves, so the submit never looks dead.
    @State private var submitting = false
    @FocusState private var inputFocused: Bool

    /// Age buckets offered in the cleanup menu.
    private let cleanupAgeChoices = [7, 30, 90]

    /// "default" means no ad-hoc effort; the profile/global default applies.
    private static let defaultEffortTag = "__default__"

    init(store: ChatStore, commandTools: CommandToolController, clientProvider: @escaping () -> LLMClient?) {
        self.store = store
        self.commandTools = commandTools
        self.clientProvider = clientProvider
        _selectedProfileID = State(initialValue: CompanionConfigService.selectedModel()?.model.id)
        _selectedEffort = State(initialValue: CompanionConfigService.adhocChatEffort().isEmpty
            ? Self.defaultEffortTag
            : CompanionConfigService.adhocChatEffort())
        _inputExpanded = State(initialValue: CompanionConfigService.chatInputExpanded())
    }

    var body: some View {
        VStack(spacing: 0) {
            if showHistory {
                historyDrawer
            }

            chatHeader

            messageList

            if let approval = commandTools.approvalRequest {
                approvalCard(approval)
            }

            if !commandTools.backgroundProcesses.isEmpty {
                backgroundProcessSection
            }

            if let error = store.errorMessage {
                errorBanner(error)
            }

            if store.isStreaming || submitting {
                statusRow
            }

            controlBar

            inputBar
        }
        .background(.background)
        .onChange(of: store.isStreaming) { _, streaming in
            // The stream owns the busy state from its first delta; when
            // it ends, a leftover submitting flag must not linger.
            if !streaming {
                submitting = false
            }
        }
        .onAppear { inputFocused = true }
        .dropDestination(for: URL.self) { urls, _ in
            guard selectedModelAcceptsImages else { return false }
            stageImages(from: urls.filter { $0.hasDirectoryPath == false })
            return true
        }
        .background(
            // Hidden anchors give the panel-scoped shortcuts a place to
            // live without stealing menu-key-equivalents from other apps.
            NewSessionShortcutAnchor {
                store.startNewSession()
            }
            .frame(width: 0, height: 0)
        )
        .background(
            // Track the panel size so the tall input can claim a share of
            // the window instead of a fixed line budget.
            GeometryReader { geo in
                Color.clear
                    .onAppear { panelHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, new in panelHeight = new }
            }
        )
    }

    // MARK: - Controls

    /// Model and reasoning effort pickers, then the working dir. Choices
    /// apply to the next message, so mid-conversation switches compare
    /// models on the same
    /// history without restarting anything.
    private var controlBar: some View {
        let providers = CompanionConfigService.chatProviders()
        let isACP = CompanionConfigService.backend() == .acp
        return HStack(spacing: 8) {
            if !isACP, !providers.isEmpty {
                Picker("Model", selection: Binding(
                    get: { selectedProfileID },
                    set: { newValue in
                        selectedProfileID = newValue
                        if let newValue {
                            CompanionConfigService.setSelectedModelProfileID(newValue)
                            // A different model changes the effective effort;
                            // its stored effort becomes the baseline.
                            let effort = providers
                                .flatMap(\.models)
                                .first { $0.id == newValue }?
                                .reasoningEffort
                            if let effort, !effort.isEmpty {
                                selectedEffort = effort
                                CompanionConfigService.setAdhocChatEffort(effort)
                            } else {
                                selectedEffort = Self.defaultEffortTag
                                CompanionConfigService.setAdhocChatEffort("")
                            }
                        }
                    }
                )) {
                    ForEach(providers) { provider in
                        Section(provider.name) {
                            ForEach(provider.models) { model in
                                Text(model.name).tag(Optional(model.id))
                            }
                        }
                    }
                }
                .controlSize(.small)
                .frame(maxWidth: 180)

                if let selected = providers
                    .flatMap(\.models)
                    .first(where: { $0.id == selectedProfileID }),
                    selected.reasoningEnabled == true {
                    Picker("Effort", selection: $selectedEffort) {
                        Text("Default").tag(Self.defaultEffortTag)
                        ForEach(CompanionConfigService.effortLevels, id: \.self) { level in
                            Text(level.capitalized).tag(level)
                        }
                    }
                    .controlSize(.small)
                    .frame(maxWidth: 110)
                    .onChange(of: selectedEffort) { _, newValue in
                        if newValue == Self.defaultEffortTag {
                            CompanionConfigService.setAdhocChatEffort("")
                        } else {
                            CompanionConfigService.setAdhocChatEffort(newValue)
                        }
                    }
                }
            }

            // The workspace rides the same row as the model pickers, so
            // the context the prompt runs in is visible at a glance.
            workingDirButton
                .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - History

    /// Sessions are stored on disk; this drawer lists them newest first
    /// and reopens any of them in place.
    private var historyDrawer: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer(minLength: 0)
                Menu {
                    ForEach(cleanupAgeChoices, id: \.self) { days in
                        Button("Older than \(days) days") {
                            store.deleteSessionsOlderThan(days: days)
                        }
                    }
                    Divider()
                    Button("All conversations", role: .destructive) {
                        confirmingDeleteAll = true
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .frame(maxWidth: 26)
                .fixedSize()
                .help("Clean up history")
                Button {
                    store.startNewSession()
                    showHistory = false
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
                .controlSize(.small)
                Button {
                    withAnimation { showHistory = false }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close history")
            }
            .padding(10)

            if confirmingDeleteAll {
                HStack {
                    Text("Delete every saved conversation? Current one included.")
                        .font(.caption)
                    Spacer(minLength: 0)
                    Button("Delete", role: .destructive) {
                        store.deleteAllSessions()
                        confirmingDeleteAll = false
                    }
                    .controlSize(.small)
                    Button("Cancel") {
                        confirmingDeleteAll = false
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.red.opacity(0.12))
            }

            Divider()

            if store.sessionHistory.isEmpty {
                Text("No saved conversations yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.sessionHistory) { session in
                            historyRow(session)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 240)
        .background(.bar)
    }

    private func historyRow(_ session: ChatSessionSummary) -> some View {
        let isCurrent = session.id == store.currentSessionID
        return HStack(spacing: 6) {
            Button {
                store.load(sessionID: session.id)
                withAnimation { showHistory = false }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title.isEmpty ? "Untitled" : session.title)
                        .font(.callout)
                        .lineLimit(1)
                    Text("\(session.messageCount) messages")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isCurrent ? Color.accentColor.opacity(0.12) : .clear)

            Button {
                store.deleteSession(id: session.id)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help("Delete conversation")
        }
    }

    // MARK: - Message list

    /// Edit affordance only on the latest user prompt: editing pulls that
    /// prompt back into the composer and truncates the thread there, so
    /// the updated version resends over the remaining history. While a
    /// response streams, editing is off (the thread is mid-update).
    private func editCallback(for message: ChatMessage) -> (() -> Void)? {
        guard !store.isStreaming,
              message.role == .user,
              message.id == store.messages.last(where: { $0.role == .user })?.id
        else { return nil }
        return { [self] in
            if let prompt = store.editLastUserPrompt() {
                draft = prompt
                inputFocused = true
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.messages.isEmpty && store.streamingText == nil {
                        emptyState
                    }

                    ForEach(store.messages) { message in
                        MessageBubble(
                            message: message,
                            onEditPrompt: editCallback(for: message)
                        )
                        .id(message.id)
                    }

                    // While only reasoning has streamed, the thinking block is
                    // the whole streaming bubble; the first answer delta swaps
                    // in the regular bubble with the thinking row folded.
                    if let streaming = store.streamingThinking,
                       (store.streamingText ?? "").isEmpty {
                        MessageBubble(
                            message: ChatMessage(
                                role: .assistant,
                                content: "",
                                thinking: streaming
                            ),
                            isStreaming: true,
                            streamingThinkingOnly: true
                        )
                        .id("streaming")
                    } else if let streaming = store.streamingText {
                        MessageBubble(
                            message: ChatMessage(
                                role: .assistant,
                                content: streaming,
                                thinking: store.streamingThinking
                            ),
                            isStreaming: true
                        )
                        .id("streaming")
                    }
                }
                .padding()
            }
            .onChange(of: store.messages.count) { _, _ in
                withAnimation {
                    if let lastID = store.messages.last?.id {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    } else {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
            }
            .onChange(of: store.streamingText) { _, _ in
                proxy.scrollTo("streaming", anchor: .bottom)
            }
            .onAppear {
                // A restored or loaded session should open at the latest
                // messages, not the top of the conversation.
                if let lastID = store.messages.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Ask anything")
                .font(.headline)
            Text("The companion answers using your configured model.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Chat header

    /// Header row: new chat and history buttons plus the YOLO toggle
    /// when command tools are active. Session controls live here, next to
    /// the context they act on, not in the input bar.
    private var chatHeader: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation { showHistory.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("Conversation history")

            // square.and.pencil is the macOS Messages glyph for ending
            // a conversation and starting a new one, so the intent reads
            // without a label.
            Button {
                store.closeAndStartNewSession()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("Close this chat and start a new one. The closed chat stays in history.")
            .disabled(!store.hasClosableSession)

            Divider()
                .frame(height: 14)

            Spacer(minLength: 0)

            if sendHandlerIsCommandAware {
                Toggle(isOn: $commandTools.yoloEnabled) {
                    Text("Auto-run (YOLO)")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(commandTools.yoloEnabled ? .red : .accentColor)
                .help(
                    commandTools.yoloEnabled
                        ? "Commands run without asking. rm and credentials files still prompt."
                        : "Ask before running anything beyond read-only commands"
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    /// The whole dir label is the picker button; the folder icon rides
    /// along so it reads as one control.
    private var workingDirButton: some View {
        Button {
            commandTools.pickWorkspace()
        } label: {
            HStack(spacing: 4) {
                Text("Working dir:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text((commandTools.effectiveWorkspaceRoot as NSString).lastPathComponent)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("\(commandTools.effectiveWorkspaceRoot). Click to choose another folder")
    }

    // MARK: - Command tools

    /// Inline confirmation card: full command, workspace, plain-words
    /// risk, three decisions.
    private func approvalCard(_ request: CommandApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run this command?")
                .font(.callout.weight(.semibold))
            Text(request.command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.bar)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("\(request.reason.label). Working folder: \((request.workspaceRoot as NSString).lastPathComponent)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Allow Once") {
                    commandTools.decide(.allowOnce)
                }
                .controlSize(.small)
                Button("Always This Session") {
                    commandTools.decide(.alwaysThisSession)
                }
                .controlSize(.small)
                Spacer(minLength: 0)
                Button("Deny", role: .destructive) {
                    commandTools.decide(.denied)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    /// Background commands with live status and Stop. Sits below the
    /// stream so it stays usable while the model writes.
    private var backgroundProcessSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(commandTools.backgroundProcesses) { process in
                HStack(spacing: 6) {
                    Circle()
                        .fill(process.running ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(process.command)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if process.running {
                        Button("Stop") {
                            Task { await commandTools.stopBackgroundProcess(process.id) }
                        }
                        .controlSize(.mini)
                    } else {
                        Text("exit \(process.exitCode ?? -1)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - Status

    /// One-line activity indicator while the model works. The label names
    /// the current phase instead of a generic spinner.
    private var statusRow: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(submitting && !store.isStreaming
                ? "Submitting…"
                : (store.activityLabel.isEmpty ? "Working…" : store.activityLabel))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button("Retry") {
                retry()
            }
            .controlSize(.small)
            Button {
                store.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.red.opacity(0.12))
    }

    // MARK: - Input

    /// True when the currently selected model takes image inputs, so the
    /// paperclip and drop/paste paths are worth showing.
    private var selectedModelAcceptsImages: Bool {
        guard CompanionConfigService.backend() == .openai else { return false }
        guard let (_, model) = CompanionConfigService.selectedModel() else { return false }
        return model.acceptsImages == true
    }

    /// Height cap for the tall composer. 45% of the panel, floored at
    /// 160pt so even a small window keeps a usable editor, and it grows
    /// as the window grows. Before the first layout pass the fallback is
    /// a sane default.
    private var inputMaxHeight: CGFloat {
        guard panelHeight > 0 else { return 220 }
        return max(160, panelHeight * 0.45)
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if !pendingImages.isEmpty {
                attachmentStrip
            }
            HStack(alignment: .bottom, spacing: 8) {
                // Expand/collapse the composer between the compact and tall
                // layouts; arrows point to where the editor grows.
                Button {
                    inputExpanded.toggle()
                    CompanionConfigService.setChatInputExpanded(inputExpanded)
                } label: {
                    Image(systemName: inputExpanded
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help(inputExpanded
                    ? "Use the compact input"
                    : "Use the tall input for longer prompts")

                if selectedModelAcceptsImages {
                    Button {
                        pickImages()
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("Attach images")
                } else {
                    Button {
                        let alert = NSAlert()
                        alert.messageText = "This model does not take images"
                        alert.informativeText = "Pick a model with the Images capability in the model editor (the Images tickbox) or switch to a vision model like Qwen3-VL in the model picker."
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Attach images (this model takes text only)")
                }

                // Scroll view caps the editor frame; the text field inside
                // sizes to its full content, so long prompts scroll instead
                // of clipping, and the tall cap follows the window size.
                ScrollView(showsIndicators: true) {
                    TextField("Ask anything…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($inputFocused)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onSubmit { send() }
                        // Shift+Return and Option+Return insert a newline so
                        // multi-line prompts stay keyboard-typed; plain
                        // Return keeps the send behavior.
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.contains(.shift)
                                || press.modifiers.contains(.option) else { return .ignored }
                            draft += "\n"
                            return .handled
                        }
                        .onPasteCommand(of: [.image, .fileURL]) { providers in
                            guard selectedModelAcceptsImages else { return }
                            stageImages(fromProviders: providers)
                        }
                }
                .frame(maxHeight: inputExpanded ? inputMaxHeight : 96)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)

                if store.isStreaming || submitting {
                    Button {
                        if store.isStreaming {
                            store.cancel()
                        } else {
                            submitting = false
                        }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help(store.isStreaming ? "Stop generating" : "Cancel submitting")
                } else {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.isEmpty && pendingImages.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (Cmd+Return)")
                }
            }
            .padding(10)
            .background(.bar)
        }
    }

    private var sendHandlerIsCommandAware: Bool {
        CompanionConfigService.commandToolsEnabled()
            && CompanionConfigService.backend() == .openai
    }

    /// Thumbnails of staged images with a remove button each.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingImages.indices, id: \.self) { index in
                    if let image = ChatAttachment.dataURIToImage(pendingImages[index]) {
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Button {
                                pendingImages.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 56)
    }

    /// File picker for image attachments. Only shown when the selected
    /// model accepts images.
    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        stageImages(from: panel.urls)
    }

    private func stageImages(from urls: [URL]) {
        for url in urls {
            guard let type = UTType(filenameExtension: url.pathExtension),
                type.conforms(to: .image)
            else { continue }
            if let dataURI = ChatAttachment.urlToDataURI(url) {
                pendingImages.append(dataURI)
            }
        }
    }

    /// Paste path: item providers carry either raw image data or a file
    /// URL. Both end up as staged data URIs.
    private func stageImages(fromProviders providers: [NSItemProvider]) {
        for provider in providers {
            if let typeID = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            }) {
                let mime = UTType(typeID)?.preferredMIMEType ?? "image/png"
                provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
                    guard let data else { return }
                    appendImageURI(data: data, mime: mime)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                        let url = URL(dataRepresentation: data, relativeTo: nil)
                    else { return }
                    DispatchQueue.main.async {
                        if let dataURI = ChatAttachment.urlToDataURI(url) {
                            pendingImages.append(dataURI)
                        }
                    }
                }
            }
        }
    }

    private func appendImageURI(data: Data, mime: String) {
        let uri = "data:\(mime);base64,\(data.base64EncodedString())"
        DispatchQueue.main.async {
            pendingImages.append(uri)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        guard !text.isEmpty || !images.isEmpty, !store.isStreaming, !submitting else { return }
        draft = ""
        pendingImages = []
        // Cover the warm-up window (server start, first model load) with
        // visible progress; the stream takes over the label once it starts.
        submitting = true
        // Local MLX profiles need the server up before the client call;
        // everything else skips straight through.
        Task { @MainActor in
            do {
                try await CompanionConfigService.ensureLocalServerIfNeeded()
            } catch {
                store.errorMessage = error.localizedDescription
                draft = text
                pendingImages = images
                submitting = false
                return
            }
            guard let client = clientProvider() else {
                store.errorMessage = "No model configured. Set it up in Preferences > Companion."
                draft = text
                pendingImages = images
                submitting = false
                return
            }
            store.send(
                text,
                images: images.isEmpty ? nil : images,
                client: client,
                effortOverride: CompanionConfigService.chatEffortOverride(),
                commandToolHandler: sendHandlerIsCommandAware
                    ? commandTools.makePanelToolHandler()
                    : nil,
                pendingBackgroundResults: sendHandlerIsCommandAware
                    ? { [weak commandTools] in await commandTools?.drainPendingResults() ?? [] }
                    : nil
            )
            // store.send sets isStreaming synchronously; if it did not
            // start (empty prompt raced a stream), drop the busy state.
            if !store.isStreaming {
                submitting = false
            }
        }
    }

    private func retry() {
        // Local MLX profiles need the server up before the client call.
        Task { @MainActor in
            do {
                try await CompanionConfigService.ensureLocalServerIfNeeded()
            } catch {
                store.errorMessage = error.localizedDescription
                return
            }
            store.retryLast(
                clientProvider: clientProvider,
                effortOverride: CompanionConfigService.chatEffortOverride(),
                commandToolHandler: sendHandlerIsCommandAware
                    ? commandTools.makePanelToolHandler()
                    : nil,
                pendingBackgroundResults: sendHandlerIsCommandAware
                    ? { [weak commandTools] in await commandTools?.drainPendingResults() ?? [] }
                    : nil
            )
        }
    }
}

// MARK: - NewSessionShortcutAnchor

/// Zero-size view whose only job is hosting the Cmd+N button so the
/// shortcut stays scoped to the chat panel (key window at the time).
private struct NewSessionShortcutAnchor: View {
    let action: () -> Void

    var body: some View {
        Button("New Chat", action: action)
            .keyboardShortcut("n", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

// MARK: - MessageBubble

struct MessageBubble: View {
    let message: ChatMessage
    var isStreaming = false
    /// True while only reasoning streams; keeps the thinking block expanded
    /// and the empty answer bubble hidden.
    var streamingThinkingOnly = false
    /// Edit affordance for the latest user prompt. Non-nil only on the
    /// last user message while nothing streams; nil everywhere else.
    var onEditPrompt: (() -> Void)? = nil

    /// Whether the user toggled the thinking block themselves; their choice
    /// wins over the automatic open-while-reasoning behavior.
    @State private var userToggledThinking = false
    @State private var thinkingExpanded = false

    private var showsThinkingRow: Bool {
        guard let thinking = message.thinking, !thinking.isEmpty, message.role == .assistant else {
            return false
        }
        return true
    }

    /// Expanded unless the user chose otherwise: auto-open while reasoning
    /// streams, folded once the answer starts or the message finished.
    private var thinkingIsExpanded: Bool {
        if userToggledThinking { return thinkingExpanded }
        return isStreaming && streamingThinkingOnly
    }

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(
                alignment: message.role == .user ? .trailing : .leading,
                spacing: 2
            ) {
                if showsThinkingRow {
                    ThinkingBlock(
                        text: message.thinking ?? "",
                        isExpanded: thinkingIsExpanded,
                        onToggle: {
                            userToggledThinking = true
                            thinkingExpanded.toggle()
                        }
                    )
                }

                if !streamingThinkingOnly {
                    if let images = message.images, !images.isEmpty, message.role == .user {
                        VStack(alignment: .trailing, spacing: 4) {
                            ForEach(images.indices, id: \.self) { index in
                                if let image = ChatAttachment.dataURIToImage(images[index]) {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: 220, maxHeight: 160)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                    if !message.content.isEmpty {
                        MarkdownContent(text: message.content, role: message.role)
                            .padding(10)
                            .background(
                                message.role == .user
                                    ? Color.accentColor.opacity(0.18)
                                    : Color(nsColor: .controlBackgroundColor)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                if isStreaming && message.content.isEmpty && !showsThinkingRow {
                    StreamingDots()
                        .padding(.leading, 10)
                }

                if let onEditPrompt, message.role == .user {
                    Button(action: onEditPrompt) {
                        Label("Edit", systemImage: "pencil.line")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Edit this prompt and resend it with the updated text")
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

// MARK: - ThinkingBlock

/// Collapsible reasoning block. A single disclosure row with a chevron and
/// secondary styling: reasoning is context for the answer, not the answer,
/// so it sits visually below it in hierarchy.
private struct ThinkingBlock: View {
    let text: String
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(isExpanded ? "Thinking" : "Thought process")
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if isExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.bar)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.leading, 2)
    }
}

// MARK: - StreamingDots

/// Three pulsing dots driven by a repeating phase animation.
private struct StreamingDots: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 4, height: 4)
                    .opacity(phase ? 1 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever().delay(Double(index) * 0.15),
                        value: phase
                    )
            }
        }
        .onAppear { phase = true }
    }
}

// MARK: - MarkdownContent

/// Schemes a chat message may open; anything else (file, ssh, custom
/// handlers) coming from model output stays inert.
private let allowedLinkSchemes: Set<String> = ["http", "https", "mailto", "tel"]

private func openChatLink(_ url: URL) {
    guard let scheme = url.scheme?.lowercased(),
          allowedLinkSchemes.contains(scheme) else { return }
    NSWorkspace.shared.open(url)
}

/// Renders one message: assistant messages parse as markdown, user
/// prompts stay verbatim.
private struct MarkdownContent: View {
    let text: String
    let role: ChatMessage.Role

    private var theme: MarkdownUI.Theme {
        MarkdownThemeFactory.chatTheme
    }

    var body: some View {
        if role == .assistant {
            Markdown(text)
                .markdownTheme(theme)
                .environment(\.openURL, OpenURLAction { url in
                    openChatLink(url)
                    return .handled
                })
                .textSelection(.enabled)
        } else {
            Text(text)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Markdown theme

enum MarkdownThemeFactory {
    /// Chat-tuned theme derived from the built-in basic theme: smaller
    /// heading scales and tighter heading margins fit the narrow panel.
    static var chatTheme: MarkdownUI.Theme {
        Theme.basic
            .heading1 { configuration in
                configuration.label
                    .markdownMargin(top: .rem(0.6), bottom: .rem(0.3))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.35))
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: .rem(0.5), bottom: .rem(0.25))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.18))
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: .rem(0.4), bottom: .rem(0.2))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.05))
                    }
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
            }
    }
}

// MARK: - ChatAttachment

/// File to data-URI conversion for image attachments. Data URIs are the
/// storage format for ChatMessage.images and what OpenAI-compatible
/// servers expect in image_url parts.
enum ChatAttachment {
    static func urlToDataURI(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "image/png"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    static func dataURIToImage(_ dataURI: String) -> NSImage? {
        guard let comma = dataURI.firstIndex(of: ",") else { return nil }
        let base64 = String(dataURI[dataURI.index(after: comma)...])
        guard let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }
}
