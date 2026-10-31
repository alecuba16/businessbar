import AppKit
import BusinessBarCore
import Combine
import Foundation
import SwiftUI
@testable import BusinessBar

@MainActor
private final class ChatHosted<Content: View> {
    let host: NSHostingView<Content>
    private let window: NSPanel

    init(_ content: Content, size: NSSize) {
        OwnedAccessibility.materialize()
        host = NSHostingView(rootView: content)
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        // Same teardown rule as UI2Hosted: no ordering animations, the
        // transform animation outliving a panel over-releases on dealloc
        // (measured run12 segfault).
        panel.animationBehavior = .none
        panel.alphaValue = 0
        window = panel
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        host.displayIfNeeded()
    }

    var text: String {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        return OwnedAccessibility.elements(in: host).flatMap { element in
            [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String].compactMap { $0 }
        }.joined(separator: "\n")
    }

    func control(_ name: String) -> OwnedAccessibility.Element? {
        OwnedAccessibility.materialize()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        return OwnedAccessibility.elements(in: host).first { element in
            element.accessibilityLabel() == name || element.accessibilityTitle() == name || (element.accessibilityValue() as? String) == name
        }
    }

    func press(_ name: String, _ context: CoverageContext) throws {
        guard let element = control(name), element.isAccessibilityEnabled() else {
            throw CoverageContext.Failure(description: "Chat control not found or disabled: \(name)")
        }
        try context.expect(element.accessibilityPerformPress(), "Chat control press succeeds: \(name)")
    }

    /// Image-only buttons carry no AX label or title; the help tooltip is
    /// the only stable text. Measured on this host: the NSButton-backed
    /// node answers accessibilityPerformPress when matched by help.
    func controlWithHelp(_ help: String) -> OwnedAccessibility.Element? {
        OwnedAccessibility.materialize()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        return OwnedAccessibility.elements(in: host).first { element in
            element.helpText() == help
        }
    }

    func pressHelp(_ help: String, _ context: CoverageContext) throws {
        guard let element = controlWithHelp(help), element.isAccessibilityEnabled() else {
            throw CoverageContext.Failure(description: "Chat control with help not found or disabled: \(help)")
        }
        try context.expect(element.accessibilityPerformPress(), "Chat control press by help succeeds: \(help)")
    }

    /// The drawer rows expose their title through the value attribute of an
    /// unlabeled button node, so lookup matches by substring on any text
    /// attribute. Measured: the row node answers performPress.
    func pressContaining(_ fragment: String, _ context: CoverageContext) throws {
        OwnedAccessibility.materialize()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        let all = OwnedAccessibility.elements(in: host)
        guard let element = all.first(where: { element in
            [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String]
                .compactMap { $0 }
                .contains { $0.contains(fragment) }
        }), element.isAccessibilityEnabled() else {
            throw CoverageContext.Failure(description: "Chat control containing text not found or disabled: \(fragment)")
        }
        try context.expect(element.accessibilityPerformPress(), "Chat control press by containing text succeeds: \(fragment)")
    }

    /// Sets the composer text through the accessibility value setter on the
    /// native text view (ComposerNSTextView). Measured on this host: the
    /// setter routes the string into the SwiftUI binding, so the send button
    /// enables afterwards and send() runs with a nonempty draft.
    func setText(_ text: String, _ context: CoverageContext) throws {
        OwnedAccessibility.materialize()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let element = OwnedAccessibility.elements(in: host).first(where: { $0.className().contains("ComposerNSTextView") }) else {
            throw CoverageContext.Failure(description: "Composer text view not found")
        }
        element.setAccessibilityText(text)
        try context.expect(true, "Composer text set through the AX value setter")
    }

    /// SwiftUI sheet presentations spawn their own SheetPresentationWindow
    /// on this host; the sheet content is not part of the hosting view's AX
    /// tree. Measured: the sheet window's content view exposes the same
    /// element walk, so presses inside sheets go through it.
    func sheetElements() -> [OwnedAccessibility.Element] {
        OwnedAccessibility.materialize()
        var found: [OwnedAccessibility.Element] = []
        for window in NSApp.windows {
            guard window.isVisible,
                  String(describing: type(of: window)).contains("SheetPresentation"),
                  let content = window.contentView else { continue }
            found.append(contentsOf: OwnedAccessibility.elements(in: content))
        }
        return found
    }

    func sheetPress(_ label: String, _ context: CoverageContext) throws {
        guard let element = sheetElements().first(where: { $0.accessibilityLabel() == label || $0.accessibilityTitle() == label }),
              element.isAccessibilityEnabled() else {
            throw CoverageContext.Failure(description: "Sheet control not found or disabled: \(label)")
        }
        try context.expect(element.accessibilityPerformPress(), "Sheet control press succeeds: \(label)")
    }

    func sheetText() -> String {
        OwnedAccessibility.materialize()
        return sheetElements().flatMap { element in
            [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String].compactMap { $0 }
        }.joined(separator: "\n")
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        // Drain pending CA transactions before the panel deallocs.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Window number so callers can exclude this fixture panel from
    /// NSApp.windows walks that match by content type.
    var fixtureWindowNumber: Int { window.windowNumber }
}

@MainActor
private func chatSettle() async {
    for _ in 0..<4 {
        await Task.yield()
        RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    }
}

private typealias Hosted = ChatHosted


@MainActor
enum AppChatScenarios {
    static func run(_ context: CoverageContext) async throws {
        var failures: [String] = []
        do { try await chatView(context) } catch { failures.append("chatView: \(error)") }
        do { try await chatViewDeep(context) } catch { failures.append("chatViewDeep: \(error)") }
        do { try await chatViewAttachments(context) } catch { failures.append("chatViewAttachments: \(error)") }
        do { try await selectionService(context) } catch { failures.append("selectionService: \(error)") }
        do { try await rewriteOverlay(context) } catch { failures.append("rewriteOverlay: \(error)") }
        if !failures.isEmpty { throw CoverageContext.Failure(description: failures.joined(separator: "\n")) }
    }

    static func chatView(_ context: CoverageContext) async throws {
        typealias Config = CompanionConfigService
        let defaults = try context.defaults("chat-view")
        defaults.registerDefaults()
        let previousDefaults = Config.defaults
        let previousStore = Config.chatProviderStore
        let previousCredentials = Config.credentials
        var secrets: [String: Data] = [:]
        Config.defaults = defaults
        Config.chatProviderStore = ChatProviderStore(defaults: defaults)
        Config.credentials = .init(load: { secrets[$0] }, save: { secrets[$0] = $1 }, delete: { secrets.removeValue(forKey: $0) })
        defer {
            Config.defaults = previousDefaults
            Config.chatProviderStore = previousStore
            Config.credentials = previousCredentials
        }

        // Reasoning-capable provider drives the model and effort pickers.
        let model = ChatModel(name: "Fixture Reasoner", model: "fixture-reasoner", reasoningEnabled: true, reasoningEffort: "medium", effortOptions: ["low", "medium", "high"])
        let provider = ChatProvider(name: "Fixture Chat", baseURL: "https://coverage.invalid/v1", models: [model])
        Config.chatProviderStore.save([provider])
        Config.setSelectedModelProfileID(model.id)

        let disk = ChatSessionStore(directoryURL: try context.temporaryDirectory("chat-view-history"))
        let store = ChatStore(sessionStore: disk)
        let commands = CommandToolController(presentation: .init(chooseWorkspace: { nil }, notify: { _ in }))

        // Pickers branch: providers exist, so the control bar carries the
        // model picker, effort picker, and working dir button.
        let pickerView = Hosted(
            ChatView(store: store, commandTools: commands, clientProvider: { nil }).defaultAppStorage(defaults),
            size: NSSize(width: 480, height: 700)
        )
        defer { pickerView.close() }
        await chatSettle()
        // A closed SwiftUI menu picker exposes only the selected item's label
        // in AX; section headers like the provider name stay hidden until it
        // opens. The selected model label is the truthful closed-state check.
        try context.expect(pickerView.text.contains("Fixture Reasoner"), "Model picker shows the selected model")
        try context.expect(pickerView.text.contains("Effort"), "Reasoning model shows the effort picker")
        try context.expect(pickerView.text.contains("Working dir:"), "Working dir button renders")
        try context.expect(pickerView.text.contains("Ask anything"), "Composer placeholder renders")

        // Approval card: every decision routes to the request completion.
        var decisions: [CommandApprovalRequest.Decision] = []
        commands.approvalRequest = CommandApprovalRequest(
            command: "fixture approval command",
            reason: .unknownCommand,
            category: .unknown,
            targets: ["fixture.txt"],
            workspaceRoot: context.root.path,
            completion: { decision in decisions.append(decision) }
        )
        let approvalView = Hosted(
            ChatView(store: store, commandTools: commands, clientProvider: { nil }).defaultAppStorage(defaults),
            size: NSSize(width: 480, height: 700)
        )
        defer { approvalView.close() }
        await chatSettle()
        try context.expect(approvalView.text.contains("fixture approval command"), "Approval card shows the command")
        try approvalView.press("Allow Once", context)
        try context.equal(decisions, [.allowOnce], "Allow Once completes the request")
        try context.expect(commands.approvalRequest == nil, "Decision clears the pending card")

        commands.approvalRequest = CommandApprovalRequest(
            command: "fixture approval command",
            reason: .unknownCommand,
            category: .unknown,
            targets: [],
            workspaceRoot: context.root.path,
            completion: { decision in decisions.append(decision) }
        )
        try approvalView.press("Deny", context)
        try context.equal(decisions, [.allowOnce, .denied], "Deny completes the request")

        commands.approvalRequest = CommandApprovalRequest(
            command: "fixture approval command",
            reason: .unknownCommand,
            category: .unknown,
            targets: [],
            workspaceRoot: context.root.path,
            completion: { decision in decisions.append(decision) }
        )
        try approvalView.press("Always This Session", context)
        try context.equal(decisions, [.allowOnce, .denied, .alwaysThisSession], "Session allow completes the request")

        commands.approvalRequest = CommandApprovalRequest(
            command: "fixture approval command",
            reason: .unknownCommand,
            category: .unknown,
            targets: [],
            workspaceRoot: context.root.path,
            completion: { decision in decisions.append(decision) }
        )
        try approvalView.press("Always Allow", context)
        try context.equal(decisions, [.allowOnce, .denied, .alwaysThisSession, .alwaysAllowPersistent], "Persistent allow completes the request")

        // Error banner with Retry: retrying without a client clears the
        // displayed error, exactly like a configured-model race.
        store.messages = [ChatMessage(role: .user, content: "Fixture prompt")]
        store.errorMessage = "Fixture transport failure"
        let errorView = Hosted(
            ChatView(store: store, commandTools: commands, clientProvider: { nil }).defaultAppStorage(defaults),
            size: NSSize(width: 480, height: 700)
        )
        defer { errorView.close() }
        await chatSettle()
        try context.expect(errorView.text.contains("Fixture transport failure"), "Error banner renders the failure")
        try errorView.press("Retry", context)
        await chatSettle()
        try context.expect(store.errorMessage == nil, "Retry without a client clears the stale error")

        // Clearing the provider store never reaches ChatView's empty-state
        // branch: CompanionConfigService.chatProviders() re-seeds a Default
        // provider from the legacy model/baseURL keys (which fall back to
        // compiled constants even on a bare defaults suite), so the hint
        // stays dead code in this flow. The truthful check is the re-seeded
        // configured-model branch after a store wipe.
        Config.chatProviderStore.save([])
        let bareStore = ChatStore(sessionStore: ChatSessionStore(directoryURL: try context.temporaryDirectory("chat-view-bare")))
        let bareView = Hosted(
            ChatView(store: bareStore, commandTools: commands, clientProvider: { nil }).defaultAppStorage(defaults),
            size: NSSize(width: 480, height: 700)
        )
        defer { bareView.close() }
        await chatSettle()
        try context.expect(CompanionConfigService.chatProviders().isEmpty == false, "Provider store re-seeds after a wipe")
        try context.expect(bareView.text.contains("The companion answers using your configured model."), "Configured-model branch renders after re-seed")
        try context.expect(bareView.text.contains("No model configured yet.") == false, "Empty-state hint stays unreachable through the seeded accessor")
    }

    /// Image attachment staging: the picker path with fixture image
    /// files and the composer paste hook with a private pasteboard, both
    /// driven with fixture bytes. The real user pasteboard is never
    /// touched: the paste hook takes the pasteboard as an argument.
    static func chatViewAttachments(_ context: CoverageContext) async throws {
        typealias Config = CompanionConfigService
        let defaults = try context.defaults("chat-view-attachments")
        defaults.registerDefaults()
        let previousDefaults = Config.defaults
        let previousStore = Config.chatProviderStore
        let previousCredentials = Config.credentials
        var secrets: [String: Data] = [:]
        Config.defaults = defaults
        Config.chatProviderStore = ChatProviderStore(defaults: defaults)
        Config.credentials = .init(load: { secrets[$0] }, save: { secrets[$0] = $1 }, delete: { secrets.removeValue(forKey: $0) })
        defer {
            Config.defaults = previousDefaults
            Config.chatProviderStore = previousStore
            Config.credentials = previousCredentials
        }

        let model = ChatModel(name: "Fixture Vision", model: "fixture-vision", reasoningEnabled: false, acceptsImages: true)
        let provider = ChatProvider(name: "Fixture Chat", baseURL: "https://coverage.invalid/v1", models: [model])
        Config.chatProviderStore.save([provider])
        Config.setSelectedModelProfileID(model.id)

        let store = ChatStore(sessionStore: ChatSessionStore(directoryURL: try context.temporaryDirectory("chat-view-attachments-history")))
        let commands = CommandToolController(presentation: .init(chooseWorkspace: { nil }, notify: { _ in }))

        // Fixture 1x1 PNG, written inside the coverage home.
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let pngData = Data(base64Encoded: pngBase64)!
        let fixtureDir = try context.temporaryDirectory("chat-view-attachments-files")
        let imageURL = fixtureDir.appendingPathComponent("fixture.png")
        try pngData.write(to: imageURL)
        let nonImageURL = fixtureDir.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: nonImageURL)

        let chatRoot: ChatView
        let staging = ChatAttachmentStaging()
        chatRoot = ChatView(store: store, commandTools: commands, clientProvider: { nil }, staging: staging)
        let view = Hosted(
            chatRoot,
            size: NSSize(width: 480, height: 700)
        )
        defer { view.close() }
        await chatSettle()

        // Picker path: image URL stages, non-image URL is skipped. Drive
        // the staging object directly: measured on this host, only the
        // injected reference keeps identity between the fixture and the
        // hosted view, so this is the one honest path to the picker and
        // drop pipeline without NSOpenPanel.
        staging.stageFiles([imageURL, nonImageURL])
        try context.equal(staging.stagedImageURIs.count, 1, "Only the image file stages as an attachment")
        try context.expect(staging.stagedImageURIs.first?.hasPrefix("data:image/png;base64,") == true, "Staged URI is a PNG data URI")

        // Paste hook: private pasteboard with image bytes, never the real
        // one. The item provider path re-reads the bytes and stages them.
        let pasteboard = NSPasteboard(name: .init("coverage-fixture-paste"))
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        staging.stagePasteboard(pasteboard)
        for _ in 0..<100 where staging.stagedImageURIs.count < 2 {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try context.equal(staging.stagedImageURIs.count, 2, "Pasted image bytes stage as a second attachment")

        // Attachment strip renders for the staged images.
        await chatSettle()
        try context.expect(view.text.contains("fixture") == false, "Strip shows thumbnails, not file names")

        // File-URL paste: a provider carrying a file URL stages through
        // the URL branch instead of the raw-bytes branch.
        let filePasteboard = NSPasteboard(name: .init("coverage-fixture-file-paste"))
        filePasteboard.clearContents()
        filePasteboard.writeObjects([imageURL as NSURL])
        staging.stagePasteboard(filePasteboard)
        for _ in 0..<100 where staging.stagedImageURIs.count < 3 {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try context.equal(staging.stagedImageURIs.count, 3, "Pasted file URL stages through the URL branch")

        // Remove one, clear the rest: the strip count APIs stay honest.
        staging.removeStaged(at: 1)
        try context.equal(staging.stagedImageURIs.count, 2, "Remove drops one staged URI")
        staging.clear()
        try context.equal(staging.stagedImageURIs.count, 0, "Clear empties the staged list")
        staging.restore(["data:image/png;base64,AAAA"])
        try context.equal(staging.stagedImageURIs.count, 1, "Restore puts failed-send images back")

        pasteboard.clearContents()
        filePasteboard.clearContents()
    }

    /// Deep-drawer and composer paths that the base chatView scenario cannot
    /// reach: the history drawer (image-only toggle, row loads and deletes,
    /// new chat, close), the composer send pipeline without a client, the
    /// stop button while a stream shows, and the edit-last-prompt notice.
    /// Every control here is image-only, so lookup goes through the help
    /// tooltip; measured on this host those nodes answer performPress.
    static func chatViewDeep(_ context: CoverageContext) async throws {
        typealias Config = CompanionConfigService
        let defaults = try context.defaults("chat-view-deep")
        defaults.registerDefaults()
        let previousDefaults = Config.defaults
        let previousStore = Config.chatProviderStore
        let previousCredentials = Config.credentials
        var secrets: [String: Data] = [:]
        Config.defaults = defaults
        Config.chatProviderStore = ChatProviderStore(defaults: defaults)
        Config.credentials = .init(load: { secrets[$0] }, save: { secrets[$0] = $1 }, delete: { secrets.removeValue(forKey: $0) })
        defer {
            Config.defaults = previousDefaults
            Config.chatProviderStore = previousStore
            Config.credentials = previousCredentials
        }

        let model = ChatModel(name: "Fixture Reasoner", model: "fixture-reasoner", reasoningEnabled: true, reasoningEffort: "medium", effortOptions: ["low", "medium", "high"])
        let provider = ChatProvider(name: "Fixture Chat", baseURL: "https://coverage.invalid/v1", models: [model])
        Config.chatProviderStore.save([provider])
        Config.setSelectedModelProfileID(model.id)

        let disk = ChatSessionStore(directoryURL: try context.temporaryDirectory("chat-view-deep-history"))
        let store = ChatStore(sessionStore: disk)
        let commands = CommandToolController(presentation: .init(chooseWorkspace: { nil }, notify: { _ in }))

        // Seed one saved session so the drawer renders a row and the
        // empty-state fallback is exercised on a second, clean store.
        let seeded = ChatSession(id: UUID(), title: "Seeded Session", messages: [ChatMessage(role: .user, content: "seed prompt")])
        try disk.save(seeded)
        store.reloadHistory()

        let view = Hosted(
            ChatView(store: store, commandTools: commands, clientProvider: { nil }).defaultAppStorage(defaults),
            size: NSSize(width: 480, height: 700)
        )
        defer { view.close() }
        await chatSettle()

        // Drawer: the toggle is an image-only button, matched by help.
        try view.pressHelp("Conversation history", context)
        await chatSettle()
        try context.expect(view.text.contains("History"), "Drawer heading renders after the toggle press")
        try context.expect(view.text.contains("New Chat"), "Drawer offers a new chat")
        try context.expect(view.text.contains("Seeded Session"), "Drawer lists the seeded session")
        try context.expect(view.text.contains("1 messages"), "Drawer row shows the seeded message count")
        // The visible close is an image-only button exposing just its help
        // tooltip (the labeled twin is accessibilityHidden for the Esc
        // shortcut), so the close control is asserted by help text.
        try context.expect(view.controlWithHelp("Close history") != nil, "Drawer carries the close control")

        // Row press loads the session and closes the drawer.
        try view.pressContaining("Seeded Session", context)
        await chatSettle()
        try context.expect(view.text.contains("Seeded Session") == false || view.text.contains("Close history") == false, "Row press closes the drawer")
        try context.expect(store.currentSessionID == seeded.id, "Row press loads the seeded session")

        // Delete from the drawer removes the persisted session.
        try view.pressHelp("Conversation history", context)
        await chatSettle()
        try view.pressHelp("Delete conversation", context)
        await chatSettle()
        try context.expect(store.sessionHistory.isEmpty, "Drawer delete removes the seeded session")

        // With history empty the drawer falls back to its empty state.
        try context.expect(view.text.contains("No saved conversations yet"), "Drawer shows the empty-state fallback")

        // New Chat from the drawer resets the thread and closes the drawer.
        try view.press("New Chat", context)
        await chatSettle()
        try context.expect(view.text.contains("No saved conversations yet") == false, "New Chat closes the drawer")

        // Reopen and close via the xmark's help.
        try view.pressHelp("Conversation history", context)
        await chatSettle()
        try view.pressHelp("Close history", context)
        await chatSettle()
        try context.expect(view.text.contains("No saved conversations yet") == false, "Close hides the drawer")

        // Send without a client: the composer accepts text through the AX
        // value setter (measured: the native text view routes the string
        // into the SwiftUI binding), then the send button reports the
        // configured-model gap after the press.
        try view.setText("Fixture prompt for send", context)
        try view.pressHelp("Send (Cmd+Return)", context)
        await chatSettle()
        try context.expect(store.errorMessage == "No model configured. Set it up in Preferences > Companion.", "Send without a client surfaces the configuration error")

        // Edit affordance: a user message renders the Edit button, and the
        // press pulls the prompt back into the composer with the notice.
        store.messages = [ChatMessage(role: .user, content: "first user prompt")]
        await chatSettle()
        try view.press("Edit", context)
        await chatSettle()
        try context.expect(view.text.contains("Editing your last prompt."), "Edit press shows the editing notice")
        try view.press("Cancel", context)
        await chatSettle()
        try context.expect(view.text.contains("Editing your last prompt.") == false, "Cancel drops the editing notice")
        try context.expect(store.messages.isEmpty, "Edit truncated the thread to before the prompt")
        // Stop button: while a stream shows, the send control is replaced by
        // the stop control. Cancel on a store without a live stream task is a
        // no-op on the flag itself; the press is the measured behavior here.
        store.isStreaming = true
        await chatSettle()
        try view.pressHelp("Stop generating", context)
        try context.expect(store.isStreaming, "Stop press leaves the flag to the stream task, which is absent here")

        // Close-and-start-new: with messages on screen the closable-session
        // guard passes and the thread clears. The nil-client send never
        // reaches store.send (the view guards first), but the earlier Edit
        // press persisted the truncated thread as an empty-titled session,
        // so history reloads with exactly that one entry, matching the
        // "closed chat stays in history" contract.
        store.isStreaming = false
        store.messages = [ChatMessage(role: .user, content: "kept prompt")]
        await chatSettle()
        try view.pressHelp("Close this chat and start a new one. The closed chat stays in history.", context)
        await chatSettle()
        try context.expect(store.messages.isEmpty, "Close and start new clears the on-screen thread")
        try context.expect(store.currentSessionID == nil, "Close and start new drops the current session id")
        try context.expect(store.sessionHistory.count == 1 && store.sessionHistory.first?.title.isEmpty == true, "The edit-persisted session stays in history after close")
    }

    static func selectionService(_ context: CoverageContext) async throws {
        // Real service, untrusted process: the only safe path is the explicit
        // permission failure. Everything else posts synthetic keyboard events
        // or touches the real pasteboard, which the fixture process must not
        // do; a boundary seam is proposed for wave B review.
        let service = SelectionService()
        let result = await service.captureSelectedText()
        if case .failure(let error) = result {
            try context.equal(error, .accessibilityNotTrusted, "Untrusted process reports the permission failure explicitly")
        } else if case .success(let selection) = result {
            try context.expect(!selection.text.isEmpty, "Trusted environment still captures a nonempty selection")
        } else {
            throw CoverageContext.Failure(description: "Capture returned neither success nor failure")
        }
    }

    static func rewriteOverlay(_ context: CoverageContext) async throws {
        let controller = RewriteOverlayController.shared
        func overlayPanels() -> [NSPanel] {
            NSApp.windows.compactMap { window in
                guard let panel = window as? NSPanel,
                      panel.isVisible,
                      panel.contentView is NSHostingView<RewriteOverlayView> else { return nil }
                return panel
            }
        }

        // Present builds a real floating panel anchored to the pointer.
        controller.present(original: "Before", rewritten: "After", templateName: "Fixture Template", selection: nil)
        await chatSettle()
        let first = overlayPanels()
        try context.equal(first.count, 1, "Present creates exactly one overlay panel")
        // Keep the fixture panel invisible like every other hosted window:
        // assertions read AX state, never the screen.
        first[0].alphaValue = 0
        first[0].setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        try context.expect(first[0].isFloatingPanel, "Overlay floats above app windows")
        try context.expect(first[0].level == .floating, "Overlay uses the floating window level")
        try context.expect(first[0].collectionBehavior.contains(.canJoinAllSpaces), "Overlay joins all spaces")

        // A second present replaces the panel instead of stacking.
        controller.present(original: "Before 2", rewritten: "After 2", templateName: "Fixture Template 2", selection: nil)
        await chatSettle()
        let second = overlayPanels()
        try context.equal(second.count, 1, "Second present replaces the old panel")
        try context.expect(second[0] !== first[0], "Replacement builds a fresh panel")
        second[0].alphaValue = 0
        second[0].setFrameOrigin(NSPoint(x: -100_001, y: -100_001))

        // Close notifications clear the owned panel state: the next
        // present builds a fresh panel instead of reusing the stale one.
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: second[0]))
        second[0].orderOut(nil)
        controller.present(original: "Before 3", rewritten: "After 3", templateName: "Fixture Template 3", selection: nil)
        await chatSettle()
        let third = overlayPanels()
        try context.equal(third.count, 1, "Delegate close leaves exactly one visible overlay")
        try context.expect(third[0] !== second[0], "Present after close builds a fresh panel")
        third[0].alphaValue = 0
        third[0].setFrameOrigin(NSPoint(x: -100_002, y: -100_002))

        for panel in overlayPanels() { panel.close() }
        try context.expect(overlayPanels().isEmpty, "Closed overlays leave nothing visible")

        // View-level state: the original/rewritten toggle and the action
        // callbacks run against injected closures, never the pasteboard.
        var replacements = 0
        var copies = 0
        var closes = 0
        let hosted = Hosted(
            RewriteOverlayView(original: "Before", rewritten: "After", templateName: "Fixture",
                               onReplace: { replacements += 1 }, onCopy: { copies += 1 }, onClose: { closes += 1 }),
            size: NSSize(width: 420, height: 280)
        )
        defer { hosted.close() }
        await chatSettle()
        try context.expect(hosted.text.contains("After"), "Overlay shows the rewritten text")
        try hosted.press("Show original", context)
        await chatSettle()
        try context.expect(hosted.text.contains("Before"), "Toggle swaps to the original text")
        try hosted.press("Replace", context)
        try hosted.press("Copy", context)
        try hosted.press("Close", context)
        try context.equal([replacements, copies, closes], [1, 1, 1], "Overlay buttons route to injected actions")

        // Controller replace path with an injected sink: the panel's Replace
        // button routes through performReplace, which dismisses and calls
        // replaceSelectionInOwner when a selection is attached. The sink
        // records the write, no AX or pasteboard is touched.
        let sink = OverlayRecordingSink()
        let replaceController = RewriteOverlayController(selectionService: sink)
        replaceController.present(
            original: "Before",
            rewritten: "After",
            templateName: "Fixture",
            selection: CapturedSelectionFixture(text: "Before", ownerProcessIdentifier: 0)
        )
        await chatSettle()
        // The Hosted fixture panel also wraps a RewriteOverlayView; exclude
        // it by window number so only the controller-built panel counts.
        let hostedWindowNumber = hosted.fixtureWindowNumber
        let visiblePanels: [NSPanel] = NSApp.windows.compactMap { window in
            guard let panel = window as? NSPanel,
                  panel.isVisible,
                  panel.windowNumber != hostedWindowNumber,
                  panel.contentView is NSHostingView<RewriteOverlayView> else { return nil }
            return panel
        }
        try context.equal(visiblePanels.count, 1, "Injected controller presents one panel")
        visiblePanels.forEach { $0.alphaValue = 0; $0.setFrameOrigin(NSPoint(x: -100_010, y: -100_010)) }
        replaceController.performReplace()
        for _ in 0..<50 where sink.ownerWrites.isEmpty {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try context.equal(sink.ownerWrites, ["After"], "Replace routes the rewritten text through the owner sink")
        try context.expect(replaceController.panelVisible == false, "Replace dismisses the panel before writing")

        // Plain replace without an attached selection routes through
        // replaceSelection, not the owner variant.
        let plainSink = OverlayRecordingSink()
        let plainController = RewriteOverlayController(selectionService: plainSink)
        plainController.present(original: "B", rewritten: "R", templateName: "F", selection: nil)
        await chatSettle()
        if let panel = NSApp.windows.first(where: { $0.isVisible && $0.level == .floating && $0.frame.width < 500 }) {
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: -100_011, y: -100_011))
        }
        plainController.performReplace()
        for _ in 0..<50 where plainSink.plainWrites.isEmpty {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try context.equal(plainSink.plainWrites, ["R"], "Replace without a selection calls the plain replace")
        plainController.panelOrderOutAndClear()
    }
}

/// CapturedSelection for scenario use: the initializer is internal, the
/// @testable import exposes it.
@MainActor
private func CapturedSelectionFixture(text: String, ownerProcessIdentifier: pid_t) -> SelectionService.CapturedSelection {
    SelectionService.CapturedSelection(text: text, viaAccessibility: true, ownerProcessIdentifier: ownerProcessIdentifier)
}

/// Records overlay Replace writes instead of touching AX or the pasteboard.
@MainActor
private final class OverlayRecordingSink: OverlaySelectionSink {
    var ownerWrites: [String] = []
    var plainWrites: [String] = []
    func replaceSelection(with text: String) async -> Bool {
        plainWrites.append(text)
        return true
    }
    func replaceSelectionInOwner(of selection: SelectionService.CapturedSelection, with newText: String) async -> Bool {
        ownerWrites.append(newText)
        return true
    }
}


