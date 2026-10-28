import BusinessBarCore
import MarkdownUI
import SwiftUI

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
    }

    var body: some View {
        VStack(spacing: 0) {
            if showHistory {
                historyDrawer
            }

            if sendHandlerIsCommandAware {
                commandHeader
            }

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

            if store.isStreaming {
                statusRow
            }

            controlBar

            inputBar
        }
        .background(.background)
        .onAppear { inputFocused = true }
        .background(
            // Hidden anchors give the panel-scoped shortcuts a place to
            // live without stealing menu-key-equivalents from other apps.
            NewSessionShortcutAnchor {
                store.startNewSession()
            }
            .frame(width: 0, height: 0)
        )
    }

    // MARK: - Controls

    /// Model and reasoning effort pickers. Choices apply to the next
    /// message, so mid-conversation switches compare models on the same
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

            Spacer(minLength: 0)

            Button {
                if let prompt = store.editLastUserPrompt() {
                    draft = prompt
                    inputFocused = true
                }
            } label: {
                Image(systemName: "pencil.line")
            }
            .buttonStyle(.plain)
            .help("Edit last prompt (put it back in the editor)")
            .disabled(!store.messages.contains { $0.role == .user } || store.isStreaming)
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

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.messages.isEmpty && store.streamingText == nil {
                        emptyState
                    }

                    ForEach(store.messages) { message in
                        MessageBubble(message: message)
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

    // MARK: - Command tools

    /// Workspace folder, YOLO toggle, and command tool status. The
    /// workspace gate reads "pick a folder" until one is chosen: every
    /// command tool errors out without it.
    private var commandHeader: some View {
        HStack(spacing: 8) {
            Button {
                commandTools.pickWorkspace()
            } label: {
                Label(
                    commandTools.workspaceRoot.map { ($0 as NSString).lastPathComponent }
                        ?? "Choose folder…",
                    systemImage: "folder"
                )
                .lineLimit(1)
            }
            .controlSize(.small)
            .help(commandTools.workspaceRoot ?? "Commands run only inside this folder")

            Spacer(minLength: 0)

            Toggle(isOn: $commandTools.yoloEnabled) {
                Text("Auto-run")
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
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

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
            Text(store.activityLabel.isEmpty ? "Working…" : store.activityLabel)
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

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                withAnimation { showHistory.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("Conversation history")

            TextField("Ask anything…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit { send() }

            if store.isStreaming {
                Button {
                    store.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Stop generating")
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(draft.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Cmd+Return)")
            }
        }
        .padding(10)
        .background(.bar)
    }

    private var sendHandlerIsCommandAware: Bool {
        CompanionConfigService.commandToolsEnabled()
            && CompanionConfigService.backend() == .openai
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.isStreaming else { return }
        draft = ""
        // Local MLX profiles need the server up before the client call;
        // everything else skips straight through.
        Task { @MainActor in
            do {
                try await CompanionConfigService.ensureLocalServerIfNeeded()
            } catch {
                store.errorMessage = error.localizedDescription
                draft = text
                return
            }
            guard let client = clientProvider() else {
                store.errorMessage = "No model configured. Set it up in Preferences > Companion."
                draft = text
                return
            }
            store.send(
                text,
                client: client,
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
                    MarkdownContent(text: message.content, role: message.role)
                        .padding(10)
                        .background(
                            message.role == .user
                                ? Color.accentColor.opacity(0.18)
                                : Color(nsColor: .controlBackgroundColor)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if isStreaming && message.content.isEmpty && !showsThinkingRow {
                    StreamingDots()
                        .padding(.leading, 10)
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
