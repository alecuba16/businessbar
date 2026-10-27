import AppKit
import BusinessBarCore
import SwiftUI

// MARK: - CompanionPanelController

/// Owns the chat NSPanel. Configured like a picture-in-picture window so it
/// floats over fullscreen apps:
/// - `.nonactivatingPanel`: clicking the panel does not steal focus from the
///   underlying app (the chat input still accepts keys via `canBecomeKey`).
/// - `.floating` level + `canJoinAllSpaces`/`fullScreenAuxiliary`: visible on
///   every space and over fullscreen windows.
/// - The level and space behavior are re-asserted on app activation and
///   screen changes; macOS occasionally drops them after display changes.
@MainActor
final class CompanionPanelController: NSObject, NSWindowDelegate {
    static let shared = CompanionPanelController()

    private var panel: NSPanel?
    private let chatStore = ChatStore()
    private var restoredOnLaunch = false

    // Zero resident cost when closed: the controller and its NSPanel are
    // created lazily on first open, and everything event-driven stops when
    // the panel closes.

    // MARK: - Present

    func togglePanel(clientProvider: @escaping () -> LLMClient?) {
        if let panel, panel.isVisible {
            close()
            return
        }
        open(clientProvider: clientProvider)
    }

    func open(clientProvider: @escaping () -> LLMClient?) {
        // Once per app launch: bring back the most recent conversation so
        // a restart resumes where it left off. Later opens keep whatever
        // is already on screen (the store survives panel close).
        if !restoredOnLaunch {
            restoredOnLaunch = true
            chatStore.restoreMostRecentSession()
        }
        let view = ChatView(store: chatStore, clientProvider: clientProvider)
        let hosting = NSHostingView(rootView: view)

        if panel == nil {
            let contentSize = NSSize(width: 420, height: 560)

            // NSPanel refuses key status by default; the subclass restores
            // keyboard input for the chat field without activating the app.
            let focusPanel = FocusablePanel(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            focusPanel.title = "BusinessBar Companion"
            focusPanel.titlebarAppearsTransparent = true
            focusPanel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            focusPanel.standardWindowButton(.zoomButton)?.isHidden = true
            focusPanel.isFloatingPanel = true
            focusPanel.level = .floating
            focusPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            focusPanel.isMovableByWindowBackground = true
            focusPanel.isReleasedWhenClosed = false
            focusPanel.delegate = self
            focusPanel.setFrameAutosaveName("CompanionChatPanel")
            focusPanel.contentView = hosting

            panel = focusPanel
            observeWorkspace()
            positionDefault(focusPanel)
            focusPanel.makeKeyAndOrderFront(nil)
        } else {
            panel?.contentView = hosting
            reassertFloating()
            panel?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.orderOut(nil)
        // Cancel any in-flight stream so no work continues while hidden.
        chatStore.cancel()
        // Kill the ACP subprocess: nothing companion-related outlives the UI.
        Task { await CompanionConfigService.shutdownACP() }
    }

    /// True when the chat panel exists and is on screen. The rewrite flow
    /// consults this before killing the shared ACP process so an open chat
    /// keeps its agent session alive.
    var isPanelVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Level re-assertion

    /// macOS sometimes drops floating level or space membership after app
    /// switches and screen changes; re-assert on those events.
    private func reassertFloating() {
        panel?.level = .floating
        panel?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    private var observers: [NSObjectProtocol] = []

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reassertFloating()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reassertFloating()
            }
        })
    }

    private func positionDefault(_ panel: NSPanel) {
        // First open: right side of the main screen, under the menu bar.
        guard let visible = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 16
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        chatStore.cancel()
    }
}

// MARK: - FocusablePanel

/// NSPanel by default refuses key status, which breaks the chat input.
/// Overriding `canBecomeKey` makes the non-activating panel accept keyboard
/// input without activating the app (same approach as Ice, PopChat, aizen).
final class FocusablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }
}

// MARK: - ChatStore

/// Chat state: message list plus the streaming conversation. Owned by the
/// panel controller so the conversation survives panel close/reopen (the
/// window is hidden, not destroyed).
@MainActor
final class ChatStore: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var streamingText: String?
    @Published var errorMessage: String?
    @Published var isStreaming = false
    @Published var activityLabel = ""
    @Published var currentSessionID: UUID?
    @Published private(set) var sessionHistory: [ChatSessionSummary] = []

    private var streamTask: Task<Void, Never>?
    private var pendingUserPrompt: String?
    private let sessionStore: ChatSessionStore

    init(sessionStore: ChatSessionStore = .shared) {
        self.sessionStore = sessionStore
        applyConfiguredRetention()
        reloadHistory()
    }

    /// Runs the retention rules from Preferences: max age in days and
    /// max session count, zero meaning that rule is off.
    func applyConfiguredRetention() {
        sessionStore.applyRetention(
            maxAgeDays: CompanionConfigService.historyMaxAgeDays(),
            maxSessionCount: CompanionConfigService.historyMaxSessions()
        )
    }

    /// Restores the most recent session on app start, so a restart never
    /// loses the conversation in progress.
    func restoreMostRecentSession() {
        guard let mostRecent = sessionHistory.first else { return }
        load(sessionID: mostRecent.id)
    }

    func reloadHistory() {
        sessionHistory = sessionStore.loadAll().map { session in
            ChatSessionSummary(
                id: session.id,
                title: session.title,
                updatedAt: session.updatedAt,
                messageCount: session.messages.count
            )
        }
    }

    func load(sessionID: UUID) {
        guard !isStreaming else { return }
        guard let session = sessionStore.load(id: sessionID) else { return }
        currentSessionID = session.id
        messages = session.messages
        errorMessage = nil
        pendingUserPrompt = nil
    }

    func startNewSession() {
        guard !isStreaming else { return }
        currentSessionID = nil
        messages = []
        errorMessage = nil
        pendingUserPrompt = nil
    }

    func deleteSession(id: UUID) {
        sessionStore.delete(id: id)
        if currentSessionID == id {
            startNewSession()
        }
        reloadHistory()
    }

    private func persistCurrentSession() {
        var session: ChatSession
        if let id = currentSessionID, let existing = sessionStore.load(id: id) {
            session = existing
            session.messages = messages
            session.updatedAt = Date()
        } else {
            session = ChatSession(id: UUID(), title: titleForCurrentSession(), messages: messages)
            currentSessionID = session.id
        }
        sessionStore.save(session)
        applyConfiguredRetention()
        reloadHistory()
    }

    // MARK: - Manual cleanup

    func deleteAllSessions() {
        sessionStore.deleteAll()
        startNewSession()
        reloadHistory()
    }

    /// Deletes sessions older than the given number of days and refreshes
    /// the list. The current conversation stays on screen even if old.
    func deleteSessionsOlderThan(days: Int) {
        sessionStore.deleteOlderThan(days: days)
        reloadHistory()
    }

    /// First user prompt becomes the session title, trimmed to fit the
    /// history list. Without a user prompt yet there is nothing worth
    /// keeping.
    private func titleForCurrentSession() -> String {
        let firstPrompt = messages.first { $0.role == .user }?.content
            ?? messages.first?.content
            ?? ""
        let singleLine = firstPrompt
            .components(separatedBy: .newlines)
            .first ?? ""
        let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(60))
    }

    func send(_ text: String, client: LLMClient) {
        guard !text.isEmpty, !isStreaming else { return }
        errorMessage = nil
        pendingUserPrompt = text
        messages.append(ChatMessage(role: .user, content: text))
        // Persist the prompt immediately: a crash mid-stream still leaves
        // the question recoverable in history.
        persistCurrentSession()
        // Set synchronously: onSubmit and the Cmd+Return button can both
        // fire in the same run loop turn, before the task body runs.
        isStreaming = true

        streamTask = Task { [weak self] in
            guard let self else { return }
            self.activityLabel = "Thinking…"
            self.streamingText = ""
            defer {
                self.isStreaming = false
                self.streamingText = nil
                self.activityLabel = ""
            }

            var assistantText = ""
            // Re-parsing markdown on every delta would burn CPU on long
            // answers, so UI updates are coalesced to ~12 per second.
            var lastUIUpdate = Date()
            let minUIInterval = 1.0 / 12.0
            do {
                let stream = await client.stream(messages: self.messages, onToolCall: nil)
                for try await event in stream {
                    switch event {
                    case .delta(let piece):
                        assistantText += piece
                        self.activityLabel = "Writing…"
                        if Date().timeIntervalSince(lastUIUpdate) >= minUIInterval {
                            lastUIUpdate = Date()
                            self.streamingText = assistantText
                        }
                    case .finished(let fullText):
                        let finalText = fullText.isEmpty ? assistantText : fullText
                        self.messages.append(ChatMessage(role: .assistant, content: finalText))
                        self.pendingUserPrompt = nil
                        self.persistCurrentSession()
                        return
                    case .failed(let message):
                        self.errorMessage = message
                        return
                    case .cancelled:
                        if !assistantText.isEmpty {
                            self.messages.append(ChatMessage(role: .assistant, content: assistantText))
                            self.persistCurrentSession()
                        }
                        return
                    case .toolCallRequested(let name, _):
                        self.activityLabel = name == "web_search" ? "Searching the web…" : "Using \(name)…"
                    }
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Re-sends the last user prompt after a failure.
    func retryLast(clientProvider: () -> LLMClient?) {
        guard !isStreaming else { return }
        // The failed attempt left the user prompt in the list; drop the
        // trailing prompt so the retry does not duplicate it.
        if let prompt = pendingUserPrompt,
           messages.last?.role == .user,
           messages.last?.content == prompt {
            messages.removeLast()
        }
        guard let prompt = pendingUserPrompt, let client = clientProvider() else {
            errorMessage = nil
            return
        }
        errorMessage = nil
        send(prompt, client: client)
    }

    func cancel() {
        streamTask?.cancel()
    }

    func clear() {
        cancel()
        messages = []
        errorMessage = nil
        pendingUserPrompt = nil
        currentSessionID = nil
    }
}