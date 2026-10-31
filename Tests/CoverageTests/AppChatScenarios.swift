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

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
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

        // Empty state with no configured model carries the setup hint.
        Config.chatProviderStore.save([])
        let bareStore = ChatStore(sessionStore: ChatSessionStore(directoryURL: try context.temporaryDirectory("chat-view-bare")))
        let bareView = Hosted(
            ChatView(store: bareStore, commandTools: commands, clientProvider: { nil }).defaultAppStorage(defaults),
            size: NSSize(width: 480, height: 700)
        )
        defer { bareView.close() }
        await chatSettle()
        try context.expect(bareView.text.contains("No model configured yet."), "Empty state names the missing setup")
        try context.expect(bareView.text.contains("Open Companion settings"), "Empty state offers the settings shortcut")
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
    }
}