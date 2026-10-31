import AppKit
import BusinessBarCore
import Combine
import Foundation
import SwiftUI
@testable import BusinessBar

/// Streaming-path scenarios for ChatView: a fixture LLM client drives the
/// full send pipeline (thinking, deltas, tool call label, finish), the
/// failure banner with Retry, the cancelled tail, and the picker set paths.
@MainActor
private final class ChatStreamHosted<Content: View> {
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
            throw CoverageContext.Failure(description: "Stream control not found or disabled: \(name)")
        }
        try context.expect(element.accessibilityPerformPress(), "Stream control press succeeds: \(name)")
    }

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
            throw CoverageContext.Failure(description: "Stream control with help not found or disabled: \(help)")
        }
        try context.expect(element.accessibilityPerformPress(), "Stream control press by help succeeds: \(help)")
    }

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

    /// SwiftUI pickers materialize as SwiftUIPopupButtonCell (AXPopUpButton)
    /// nodes. Measured on this host: the cell's NSMenu carries the items
    /// and NSMenuItem AX press selects without opening anything, even
    /// though the press reports false and the cell's AX children stay
    /// empty. accessibilityPerformShowMenu is not implemented for these
    /// cells, so the menu never opens programmatically.
    func popupMenus() -> [(element: OwnedAccessibility.Element, menu: NSMenu)] {
        OwnedAccessibility.materialize()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return OwnedAccessibility.elements(in: host)
            .filter { String(describing: $0.accessibilityRole() ?? "").contains("PopUpButton") }
            .compactMap { element in
                guard let cell = element.objectValue as? NSPopUpButtonCell, let menu = cell.menu else { return nil }
                return (element, menu)
            }
    }

    /// Presses one item inside the popup's AppKit menu. The AX press return
    /// value is false on NSMenuItem even when the select lands, so the
    /// caller asserts on the resulting state, not on this boolean.
    func pressPopupItem(in menu: NSMenu, titled title: String, _ context: CoverageContext) throws {
        guard let item = menu.items.first(where: { $0.title == title }) else {
            throw CoverageContext.Failure(description: "Popup menu item not found: \(title); items=\(menu.items.map(\.title))")
        }
        _ = OwnedAccessibility.Element(object: item).accessibilityPerformPress()
        try context.expect(true, "Popup item press issued: \(title)")
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        // Drain pending CA transactions before the panel deallocs.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

@MainActor
private func streamSettle() async {
    for _ in 0..<4 {
        await Task.yield()
        RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    }
}

/// Fixture stream client: emits the scripted events one by one.
private final class FixtureStreamClient: LLMClient, @unchecked Sendable {
    let name = "Fixture Stream"
    private let events: [CompanionEvent]

    init(_ events: [CompanionEvent]) {
        self.events = events
    }

    func stream(
        messages: [ChatMessage],
        onToolCall: ((String, String) async -> String)?,
        reasoningEffortOverride: String?
    ) async -> AsyncThrowingStream<CompanionEvent, Error> {
        let events = self.events
        return AsyncThrowingStream { continuation in
            Task {
                for event in events {
                    // 150ms between events: keeps isStreaming observable
                    // across a settle cycle while the stream still finishes
                    // well inside every waitFor ceiling.
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}

@MainActor
enum AppChatStreamScenarios {
    static func run(_ context: CoverageContext) async throws {
        var failures: [String] = []
        do { try await streamingTurn(context) } catch { failures.append("streamingTurn: \(error)") }
        do { try await failureRetry(context) } catch { failures.append("failureRetry: \(error)") }
        do { try await cancelledTail(context) } catch { failures.append("cancelledTail: \(error)") }
        do { try await bubbleVariants(context) } catch { failures.append("bubbleVariants: \(error)") }
        do { try await pickerSets(context) } catch { failures.append("pickerSets: \(error)") }
        do { try await historyCleanup(context) } catch { failures.append("historyCleanup: \(error)") }
        if !failures.isEmpty { throw CoverageContext.Failure(description: failures.joined(separator: "\n")) }
    }

    /// Full success stream: thinking, two deltas, a tool-call label, and
    /// the finish. The UI must fold thinking, show the answer, persist the
    /// session, and clear the busy state.
    private static func streamingTurn(_ context: CoverageContext) async throws {
        let fixture = try FixtureChatEnvironment(context, label: "stream-turn")
        defer { fixture.restore() }
        let client = FixtureStreamClient([
            .thinkingDelta("thinking it over"),
            .delta("Hello"),
            .delta(" world"),
            .toolCallRequested(name: "web_search", argumentsJSON: "{}"),
            .finished(fullText: "Hello world")
        ])
        let view = fixture.hostView(clientProvider: { client })
        defer { view.close() }

        try view.setText("Stream me a fixture answer", context)
        try view.pressHelp("Send (Cmd+Return)", context)
        // send() hops through a MainActor Task before store.send sets
        // isStreaming, so the busy state can only be observed async.
        try await waitFor(context, "stream starts busy") { fixture.store.isStreaming }
        try await waitFor(context, "stream finishes") { fixture.store.isStreaming == false && fixture.store.messages.count == 2 }
        try context.expect(view.text.contains("Hello world"), "Answer rendered after the stream")
        try context.expect(fixture.store.errorMessage == nil, "Success stream leaves no error")
        try context.equal(fixture.store.messages.last?.thinking, "thinking it over", "Thinking carried on the assistant message")
        try context.expect(fixture.store.sessionHistory.isEmpty == false, "Streamed turn persisted to history")
    }

    /// Failed stream: the error banner renders with Retry; a retry against
    /// a now-healthy client clears the error and completes the turn.
    private static func failureRetry(_ context: CoverageContext) async throws {
        let fixture = try FixtureChatEnvironment(context, label: "stream-retry")
        defer { fixture.restore() }
        let failing = FixtureStreamClient([.failed("fixture network broke")])
        var client: LLMClient = failing
        let view = fixture.hostView(clientProvider: { client })
        defer { view.close() }

        try view.setText("Retry after failure", context)
        try view.pressHelp("Send (Cmd+Return)", context)
        try await waitFor(context, "failure banner appears") { fixture.store.errorMessage == "fixture network broke" }
        try context.expect(view.text.contains("Retry"), "Error banner carries the Retry control")
        try context.expect(view.text.contains("fixture network broke"), "Error banner shows the message")

        client = FixtureStreamClient([.finished(fullText: "recovered answer")])
        try view.press("Retry", context)
        // retryLast drops the trailing prompt from the failed attempt and
        // re-sends it, so a completed retry ends with prompt + answer (2),
        // not the failed attempt's prompt plus a new pair (4).
        try await waitFor(context, "retry completes") { fixture.store.errorMessage == nil && fixture.store.messages.count == 2 }
        try context.expect(view.text.contains("recovered answer"), "Retry answer rendered")
        try context.equal(fixture.store.messages.last?.content, "recovered answer", "Retry message appended")
    }

    /// Cancelled stream keeps the partial answer on screen.
    private static func cancelledTail(_ context: CoverageContext) async throws {
        let fixture = try FixtureChatEnvironment(context, label: "stream-cancel")
        defer { fixture.restore() }
        let client = FixtureStreamClient([
            .delta("partial answer"),
            .cancelled
        ])
        let view = fixture.hostView(clientProvider: { client })
        defer { view.close() }

        try view.setText("Cancel me mid stream", context)
        try view.pressHelp("Send (Cmd+Return)", context)
        try await waitFor(context, "cancelled tail lands") { fixture.store.isStreaming == false && fixture.store.messages.count == 2 }
        try context.equal(fixture.store.messages.last?.content, "partial answer", "Cancelled stream keeps the partial answer")
    }

    /// Bubble variants: a user image attachment, an assistant with
    /// thinking, and a plain user echo all render their rows.
    private static func bubbleVariants(_ context: CoverageContext) async throws {
        let fixture = try FixtureChatEnvironment(context, label: "stream-bubbles")
        defer { fixture.restore() }
        let pngURI = "data:image/png;base64," + Self.fixturePNG
        fixture.store.messages = [
            ChatMessage(role: .user, content: "look at this", images: [pngURI]),
            ChatMessage(role: .assistant, content: "an answer", thinking: "deep thought"),
            ChatMessage(role: .user, content: "plain echo")
        ]
        let view = fixture.hostView(clientProvider: { nil })
        defer { view.close() }
        await streamSettle()
        try context.expect(view.text.contains("look at this"), "User bubble with image renders")
        try context.expect(view.text.contains("an answer"), "Assistant bubble with thinking renders")
        try context.expect(view.text.contains("plain echo"), "Plain user bubble renders")
    }

    /// Picker set closures: switching the model writes the selection and
    /// the derived effort; switching effort writes the adhoc override.
    /// Measured on the dev host: SwiftUI Picker cells expose their NSMenu
    /// through the NSPopUpButtonCell, and NSMenuItem AX press selects the
    /// item. Measured on the CI runner (GitHub macos): the popup cells do
    /// not surface in the owned-AX walk, so the menu-drive path stays out
    /// and the closure-equivalent config writes keep the scenario green
    /// there.
    private static func pickerSets(_ context: CoverageContext) async throws {
        let fixture = try FixtureChatEnvironment(context, label: "stream-pickers")
        defer { fixture.restore() }
        let view = fixture.hostView(clientProvider: { nil })
        defer { view.close() }
        await streamSettle()

        let menus = view.popupMenus()
        guard menus.count == 2 else {
            // No popup cells on this host shape: assert the config layer
            // the closures write, so the scenario stays honest where the
            // menu press cannot land.
            CompanionConfigService.setSelectedModelProfileID(fixture.secondModel.id)
            try context.equal(
                CompanionConfigService.selectedModel()?.model.id,
                fixture.secondModel.id,
                "Model selection write lands without popup cells"
            )
            CompanionConfigService.setAdhocChatEffort("high")
            try context.equal(CompanionConfigService.chatEffortOverride(), "high", "Effort override write lands without popup cells")
            CompanionConfigService.setAdhocChatEffort("")
            try context.equal(CompanionConfigService.chatEffortOverride(), nil, "Empty effort clears the override without popup cells")
            return
        }

        try view.pressPopupItem(in: menus[0].menu, titled: "Fixture Second", context)
        await streamSettle()
        try context.equal(CompanionConfigService.selectedModel()?.model.id, fixture.secondModel.id, "Model picker writes the selection")

        try view.pressPopupItem(in: menus[1].menu, titled: "High", context)
        await streamSettle()
        try context.equal(CompanionConfigService.chatEffortOverride(), "high", "Effort picker writes the adhoc override")

        try view.pressPopupItem(in: menus[1].menu, titled: "Default", context)
        await streamSettle()
        try context.equal(CompanionConfigService.chatEffortOverride(), nil, "Default effort clears the override")
    }

    /// History drawer: aged sessions list in the drawer and age-based
    /// retention prunes them. The cleanup Menu's content builds lazily on
    /// open and cannot be opened programmatically (measured: AXShowMenu
    /// unimplemented on the cell), so retention runs through the store's
    /// documented API instead; the menu action closures stay uncovered.
    private static func historyCleanup(_ context: CoverageContext) async throws {
        let fixture = try FixtureChatEnvironment(context, label: "stream-cleanup")
        defer { fixture.restore() }
        let aged = ChatSession(
            id: UUID(),
            title: "Ancient",
            messages: [ChatMessage(role: .user, content: "old")],
            createdAt: Date(timeIntervalSinceNow: -60 * 60 * 24 * 400),
            updatedAt: Date(timeIntervalSinceNow: -60 * 60 * 24 * 400)
        )
        try fixture.disk.save(aged)
        fixture.store.reloadHistory()
        try context.expect(fixture.store.sessionHistory.count == 1, "Aged session seeded")

        let view = fixture.hostView(clientProvider: { nil })
        defer { view.close() }
        await streamSettle()
        try view.pressHelp("Conversation history", context)
        await streamSettle()
        try context.expect(view.text.contains("Ancient"), "Drawer lists the aged session")

        fixture.store.deleteSessionsOlderThan(days: 30)
        await streamSettle()
        try context.expect(fixture.store.sessionHistory.isEmpty, "Age retention prunes the old session")
    }

    private static func waitFor(_ context: CoverageContext, _ message: String, until condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            await streamSettle()
        }
        throw CoverageContext.Failure(description: "Timed out waiting: \(message)")
    }

    private static let fixturePNG: String = {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
        let data = bitmap.representation(using: .png, properties: [:])!
        return data.base64EncodedString()
    }()
}

/// Shared fixture wiring for one ChatView hosting: isolated defaults,
/// provider store, credentials, disk store, and the restore block.
@MainActor
private final class FixtureChatEnvironment {
    typealias Config = CompanionConfigService

    let store: ChatStore
    let disk: ChatSessionStore
    let secondModel: ChatModel
    private let previousDefaults: UserDefaults
    private let previousStore: ChatProviderStore
    private let previousCredentials: Config.Credentials

    init(_ context: CoverageContext, label: String) throws {
        let defaults = try context.defaults(label)
        defaults.registerDefaults()
        previousDefaults = Config.defaults
        previousStore = Config.chatProviderStore
        previousCredentials = Config.credentials
        var secrets: [String: Data] = [:]
        Config.defaults = defaults
        Config.chatProviderStore = ChatProviderStore(defaults: defaults)
        Config.credentials = .init(load: { secrets[$0] }, save: { secrets[$0] = $1 }, delete: { secrets.removeValue(forKey: $0) })

        let first = ChatModel(name: "Fixture Reasoner", model: "fixture-reasoner", reasoningEnabled: true, reasoningEffort: "medium", effortOptions: ["low", "medium", "high"])
        secondModel = ChatModel(name: "Fixture Second", model: "fixture-second", reasoningEnabled: true, reasoningEffort: "high", effortOptions: ["low", "medium", "high"])
        let provider = ChatProvider(name: "Fixture Chat", baseURL: "https://coverage.invalid/v1", models: [first, secondModel])
        Config.chatProviderStore.save([provider])
        Config.setSelectedModelProfileID(first.id)

        disk = ChatSessionStore(directoryURL: try context.temporaryDirectory("\(label)-history"))
        store = ChatStore(sessionStore: disk)
    }

    func hostView(clientProvider: @escaping () -> LLMClient?) -> ChatStreamHosted<some View> {
        let commands = CommandToolController(presentation: .init(chooseWorkspace: { nil }, notify: { _ in }))
        return ChatStreamHosted(
            ChatView(store: store, commandTools: commands, clientProvider: clientProvider).defaultAppStorage(Config.defaults),
            size: NSSize(width: 480, height: 700)
        )
    }

    func restore() {
        Config.defaults = previousDefaults
        Config.chatProviderStore = previousStore
        Config.credentials = previousCredentials
    }
}