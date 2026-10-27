import BusinessBarCore
import MarkdownUI
import SwiftUI

// MARK: - ChatView

/// Streaming chat UI hosted in the companion panel. Assistant messages
/// render as markdown (headings, code blocks, links, images); user prompts
/// render verbatim so what was asked is always readable.
struct ChatView: View {
    @ObservedObject var store: ChatStore
    let clientProvider: () -> LLMClient?

    @State private var draft: String = ""
    @State private var showHistory = false
    @State private var confirmingDeleteAll = false
    @FocusState private var inputFocused: Bool

    /// Age buckets offered in the cleanup menu.
    private let cleanupAgeChoices = [7, 30, 90]

    var body: some View {
        VStack(spacing: 0) {
            if showHistory {
                historyDrawer
            }

            messageList

            if let error = store.errorMessage {
                errorBanner(error)
            }

            if store.isStreaming {
                statusRow
            }

            inputBar
        }
        .background(.background)
        .onAppear { inputFocused = true }
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

                    if let streaming = store.streamingText {
                        MessageBubble(
                            message: ChatMessage(role: .assistant, content: streaming),
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
                store.retryLast(clientProvider: clientProvider)
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

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.isStreaming else { return }
        guard let client = clientProvider() else {
            store.errorMessage = "No model configured. Set it up in Preferences > Companion."
            return
        }
        draft = ""
        store.send(text, client: client)
    }
}

// MARK: - MessageBubble

struct MessageBubble: View {
    let message: ChatMessage
    var isStreaming = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(
                alignment: message.role == .user ? .trailing : .leading,
                spacing: 2
            ) {
                MarkdownContent(text: message.content, role: message.role)
                    .padding(10)
                    .background(
                        message.role == .user
                            ? Color.accentColor.opacity(0.18)
                            : Color(nsColor: .controlBackgroundColor)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if isStreaming && message.content.isEmpty {
                    StreamingDots()
                        .padding(.leading, 10)
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
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
