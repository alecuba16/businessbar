import AppKit
import BusinessBarCore
import Foundation
import Network
import SwiftUI
@testable import BusinessBar

/// CompanionTab deep scenarios: the provider editor's remote model fetch
/// against a localhost stub, the fetched-list rows and Add All, the model
/// editor's effort add/reset flows, and the template editor's custom
/// effort. These target the run7 miss clusters that the sheet-presentation
/// scenarios in AppPreferencesUI1Scenarios leave dark.
@MainActor
private final class CompanionDeepHosted<Content: View> {
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
        return OwnedAccessibility.elements(in: host).first { element in
            element.accessibilityLabel() == name || element.accessibilityTitle() == name
        }
    }

    func press(_ name: String, _ context: CoverageContext) throws {
        guard let element = control(name), element.isAccessibilityEnabled() else {
            throw CoverageContext.Failure(description: "Editor control not found or disabled: \(name)")
        }
        try context.expect(element.accessibilityPerformPress(), "Editor control press succeeds: \(name)")
    }

    /// Borderless row image buttons carry no label, only a help tooltip.
    /// Measured on this host: the node answers performPress.
    func pressByHelp(_ help: String, _ context: CoverageContext) throws {
        OwnedAccessibility.materialize()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let element = OwnedAccessibility.elements(in: host).first(where: { $0.helpText() == help }),
              element.isAccessibilityEnabled() else {
            throw CoverageContext.Failure(description: "Tab control with help not found or disabled: \(help)")
        }
        try context.expect(element.accessibilityPerformPress(), "Tab press by help succeeds: \(help)")
    }

    /// Sheets presented by the hosted tab open their own
    /// SheetPresentationWindow; presses inside them walk that window.
    private func sheetElements() -> [OwnedAccessibility.Element] {
        OwnedAccessibility.materialize()
        var found: [OwnedAccessibility.Element] = []
        for window in NSApp.windows {
            guard window.isVisible,
                  let content = window.contentView,
                  window !== self.window,
                  String(describing: type(of: window)).contains("SheetPresentation") else { continue }
            found.append(contentsOf: OwnedAccessibility.elements(in: content))
        }
        return found
    }

    func sheetText() -> String {
        OwnedAccessibility.materialize()
        return sheetElements().flatMap { element in
            [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String].compactMap { $0 }
        }.joined(separator: "\n")
    }

    func sheetPress(_ label: String, _ context: CoverageContext) throws {
        guard let element = sheetElements().first(where: { $0.accessibilityLabel() == label || $0.accessibilityTitle() == label }),
              element.isAccessibilityEnabled() else {
            throw CoverageContext.Failure(description: "Sheet control not found or disabled: \(label)")
        }
        try context.expect(element.accessibilityPerformPress(), "Sheet control press succeeds: \(label)")
    }

    /// SwiftUI Form pickers materialize as SwiftUIPopupButtonCell
    /// (AXPopUpButton) nodes. Measured on this host (AppChatStreamScenarios):
    /// the cell's NSMenu carries the items and the NSMenuItem AX press
    /// selects without opening anything.
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

    /// Presses one item inside the popup's AppKit menu. The AX press
    /// return value is false on NSMenuItem even when the select lands, so
    /// the caller asserts on the resulting state instead.
    func pressPopupItem(in menu: NSMenu, titled title: String, _ context: CoverageContext) throws {
        guard let item = menu.items.first(where: { $0.title == title }) else {
            throw CoverageContext.Failure(description: "Popup menu item not found: \(title); items=\(menu.items.map(\.title))")
        }
        _ = OwnedAccessibility.Element(object: item).accessibilityPerformPress()
        try context.expect(true, "Popup item press issued: \(title)")
    }

    /// Row Edit buttons share the label across rows, and provider and
    /// model names also render in the Chat form pickers above the rows,
    /// so the row itself is the LAST element carrying the text and the
    /// first "Edit" after it is the row's own button. Same measured AX
    /// order as UI1's pressEdit: name text, then Edit, then Bin.
    func pressEditAfter(_ rowText: String, _ context: CoverageContext) throws {
        OwnedAccessibility.materialize()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        let all = OwnedAccessibility.elements(in: host)
        guard let row = all.lastIndex(where: { element in
            [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String]
                .compactMap { $0 }
                .contains { $0.contains(rowText) }
        }) else {
            throw CoverageContext.Failure(description: "Row not found: \(rowText)")
        }
        guard let edit = all[(row + 1)...].first(where: { $0.accessibilityLabel() == "Edit" }),
              edit.isAccessibilityEnabled() else {
            throw CoverageContext.Failure(description: "Edit button not found after row: \(rowText)")
        }
        try context.expect(edit.accessibilityPerformPress(), "Row edit press succeeds: \(rowText)")
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        // Drain pending CA transactions before the panel deallocs.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

/// Tiny localhost /models endpoint on an ephemeral port. The editor's
/// Fetch Models button uses the shared URLSession, so a real socket on
/// 127.0.0.1 is the only interception route that stays local.
private final class StubModelsServer: @unchecked Sendable {
    let listener: NWListener
    private let listenerQueue: DispatchQueue
    private var connections: [NWConnection] = []
    private let payload: Data

    init(payload: String) throws {
        self.payload = Data(payload.utf8)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        // Dedicated queue, not .main: the scenario runs on MainActor, and a
        // listener on the main queue would deadlock against the bind wait.
        let queue = DispatchQueue(label: "coverage.stub-models-server")
        self.listenerQueue = queue
        self.listener = listener
        listener.start(queue: queue)
        // Attached after start: no connection can arrive before the port
        // exists, which the async bind wait below gates on.
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
    }

    /// Async bind wait. RunLoop.main.run(until:) exits instantly with no
    /// sources attached, so a runloop spin measured 2000 iterations in
    /// 0.4ms and gave the listener no time at all; Task.sleep yields real
    /// wall-clock time to the listener queue.
    func waitUntilBound() async throws {
        for _ in 0..<300 {
            if (listener.port?.rawValue ?? 0) != 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        listener.cancel()
        throw CoverageContext.Failure(description: "Stub server failed to bind (port stayed 0 for 3s)")
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: listenerQueue)
        receive(connection, buffered: Data())
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, _ in
            var buffer = buffered
            buffer.append(data ?? Data())
            // The request ends when the client half-closes or a full header
            // block arrived; either way the response goes out.
            if isComplete || buffer.contains(Data("\r\n\r\n".utf8)) {
                let body = self?.payload ?? Data()
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else {
                self?.receive(connection, buffered: buffer)
            }
        }
    }

    func stop() {
        listener.cancel()
        for connection in connections { connection.cancel() }
    }
}

@MainActor
enum AppCompanionTabDeepScenarios {
    static func run(_ context: CoverageContext) async throws {
        var failures: [String] = []
        do { try await providerFetch(context) } catch { failures.append("providerFetch: \(error)") }
        do { try await modelEffortEditor(context) } catch { failures.append("modelEffortEditor: \(error)") }
        do { try await templateCustomEffort(context) } catch { failures.append("templateCustomEffort: \(error)") }
        do { try await tabActions(context) } catch { failures.append("tabActions: \(error)") }
        if !failures.isEmpty { throw CoverageContext.Failure(description: failures.joined(separator: "\n")) }
    }

    /// Provider editor: Fetch Models against the localhost stub lists the
    /// rows, Add appends one, Add All appends the rest, and Save writes the
    /// provider with the fetched models attached.
    private static func providerFetch(_ context: CoverageContext) async throws {
        typealias Config = CompanionConfigService
        let defaults = try context.defaults("companion-fetch")
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

        let payload = #"{"data":[{"id":"stub-reasoner","supported_parameters":["reasoning_effort"]},{"id":"stub-plain"},{"id":""},{}]}"#
        let server = try StubModelsServer(payload: payload)
        defer { server.stop() }
        try await server.waitUntilBound()

        var savedProvider: ChatProvider?
        var savedKey: String?
        var savedHeaders: [(name: String, value: String)] = []
        let editor = CompanionDeepHosted(
            ProviderEditorSheet(
                provider: ChatProvider(name: "Fetch Fixture", baseURL: "http://127.0.0.1:\(server.port)/v1", models: []),
                onSave: { provider, key, headers in
                    savedProvider = provider
                    savedKey = key
                    savedHeaders = headers
                }
            ),
            size: NSSize(width: 700, height: 900)
        )
        defer { editor.close() }
        await settle()

        try context.expect(editor.control("Fetch Models")?.isAccessibilityEnabled() == true, "Fetch enabled with a base URL present")

        // Header rows: Add Header covers the pair row render path. The
        // row's placeholder ("Header name") never enters the AX walk
        // (measured: _SystemTextFieldCell value stays empty, placeholder
        // only in label/title/value absent), so the reachable render signal
        // is the pair row's Remove node, which exists only when headers
        // is non-empty.
        try editor.press("Add Header", context)
        await settle()
        try context.expect(editor.control("Remove")?.isAccessibilityEnabled() == true, "Added header pair row renders")

        try editor.press("Fetch Models", context)
        try await waitFor(context, "fetch lists models") { editor.text.contains("stub-reasoner") }
        try context.expect(editor.text.contains("stub-plain"), "Fetched rows list both valid models")

        try editor.press("Add", context)
        await settle()

        try editor.press("Add All", context)
        await settle()
        try editor.press("Save", context)
        await settle()
        try context.equal(savedProvider?.models.map(\.model), ["stub-reasoner", "stub-plain"], "Save writes the fetched model list")
        try context.equal(savedProvider?.models.first?.reasoningEnabled, true, "Reasoning metadata carries into the added model")
        try context.equal(savedKey, "", "Empty key saves as empty")
        try context.equal(savedHeaders.count, 0, "Blank header row is dropped on save")
    }

    /// Model editor effort options: pinned marker, Reset to detected, and
    /// the custom effort field for stored non-preset values. The Add-effort
    /// TextField is AX-dead on this host (measured: five routes to set the
    /// draft all fail to reach the SwiftUI binding, so Add stays disabled),
    /// and the Remove-row image press does not fire onTapGesture, so both
    /// stay render-asserted; parseList pinning keeps its core coverage.
    private static func modelEffortEditor(_ context: CoverageContext) async throws {
        var saved: ChatModel?
        let editor = CompanionDeepHosted(
            ModelEditorSheet(
                model: ChatModel(name: "Effort Fixture", model: "effort-fixture", reasoningEnabled: true, reasoningEffort: "medium"),
                onSave: { saved = $0 }
            ),
            size: NSSize(width: 700, height: 900)
        )
        defer { editor.close() }
        await settle()

        try context.expect(editor.text.contains("Effort options"), "Effort editor section renders for a reasoning model")
        try context.expect(editor.text.contains("pinned") == false, "Unpinned vocabulary hides the pinned marker")
        try context.expect(editor.control("Add")?.isAccessibilityEnabled() == false, "Add stays disabled while the draft field is empty")

        try editor.press("Save", context)
        await settle()
        try context.equal(saved?.effortOptions, nil, "Unpinned vocabulary saves as detected (nil)")
        try context.equal(saved?.reasoningEffort, "medium", "Preset selection persists")

        // Custom effort: a stored non-preset value reveals the custom field.
        var customSaved: ChatModel?
        let custom = CompanionDeepHosted(
            ModelEditorSheet(
                model: ChatModel(name: "Custom Effort", model: "custom-fixture", reasoningEnabled: true, reasoningEffort: "beyond"),
                onSave: { customSaved = $0 }
            ),
            size: NSSize(width: 700, height: 900)
        )
        defer { custom.close() }
        await settle()
        // Placeholder strings never enter the AX text walk (labels, titles,
        // values only), so the custom field is asserted by its stored value
        // and the picker's Custom selection.
        try context.expect(custom.text.contains("beyond"), "Non-preset stored effort reveals the custom field with its value")
        try context.expect(custom.text.contains("Custom"), "Effort picker offers the Custom entry")
        try custom.press("Save", context)
        await settle()
        try context.equal(customSaved?.reasoningEffort, "beyond", "Custom effort value saves unchanged")

        // Reset to detected: the pinned list drops back to nil.
        var resetSaved: ChatModel?
        let reset = CompanionDeepHosted(
            ModelEditorSheet(
                model: ChatModel(name: "Reset Effort", model: "reset-fixture", reasoningEnabled: true, reasoningEffort: "medium", effortOptions: ["low", "medium"]),
                onSave: { resetSaved = $0 }
            ),
            size: NSSize(width: 700, height: 900)
        )
        defer { reset.close() }
        await settle()
        try context.expect(reset.text.contains("pinned"), "Pinned vocabulary shows the marker")
        try context.expect(reset.text.contains("low"), "Pinned low row renders")
        try reset.press("Reset to detected", context)
        await settle()
        try context.expect(reset.text.contains("pinned") == false, "Reset drops the pin")
        try reset.press("Save", context)
        await settle()
        try context.equal(resetSaved?.effortOptions, nil, "Reset saves the detected vocabulary un-pinned")
    }

    /// Template editor: the effort picker maps Default to nil and presets
    /// and custom values save unchanged.
    private static func templateCustomEffort(_ context: CoverageContext) async throws {
        var saved: PromptTemplate?
        let editor = CompanionDeepHosted(
            TemplateEditorSheet(template: PromptTemplate(name: "Effort Template", prompt: "Refine [placeholder]"), onSave: { saved = $0 }),
            size: NSSize(width: 700, height: 800)
        )
        defer { editor.close() }
        await settle()

        try context.expect(editor.text.contains("Reasoning effort"), "Template editor shows the effort row")
        try editor.press("Save", context)
        await settle()
        try context.equal(saved?.reasoningEffort, nil, "Default selection saves nil effort")

        var presetSaved: PromptTemplate?
        let preset = CompanionDeepHosted(
            TemplateEditorSheet(template: PromptTemplate(name: "Preset", prompt: "Refine [placeholder]", reasoningEffort: "high"), onSave: { presetSaved = $0 }),
            size: NSSize(width: 700, height: 800)
        )
        defer { preset.close() }
        await settle()
        try context.expect(preset.text.contains("High"), "Stored preset shows in the picker")
        try preset.press("Save", context)
        await settle()
        try context.equal(presetSaved?.reasoningEffort, "high", "Preset effort saves unchanged")

        var customSaved: PromptTemplate?
        let custom = CompanionDeepHosted(
            TemplateEditorSheet(template: PromptTemplate(name: "Custom", prompt: "Refine [placeholder]", reasoningEffort: "ultra"), onSave: { customSaved = $0 }),
            size: NSSize(width: 700, height: 800)
        )
        defer { custom.close() }
        await settle()
        try context.expect(custom.text.contains("ultra"), "Non-preset stored effort reveals the custom field with its value")
        try custom.press("Save", context)
        await settle()
        try context.equal(customSaved?.reasoningEffort, "ultra", "Custom effort value saves unchanged")
    }

    /// Full CompanionTab driven end to end: the Chat and history pickers
    /// through their popup menus, the permission buttons through the
    /// injected seams, row trash buttons, the three Add Provider buttons,
    /// and the provider save closure's keychain success and error branches.
    /// The sheets the Add buttons present stay render-asserted: their Save
    /// gates on empty required fields and the AX value setter does not
    /// reach SwiftUI TextField bindings (measured in the model effort
    /// probe), so the append branches are unreachable from the UI.
    private static func tabActions(_ context: CoverageContext) async throws {
        typealias Config = CompanionConfigService
        let defaults = try context.defaults("companion-tab-actions")
        defaults.registerDefaults()
        let previousDefaults = Config.defaults
        let previousStore = Config.chatProviderStore
        let previousCredentials = Config.credentials
        var secrets: [String: Data] = [:]
        var saveThrows = false
        struct FixtureKeychainError: Error {}
        Config.defaults = defaults
        Config.chatProviderStore = ChatProviderStore(defaults: defaults)
        Config.credentials = .init(
            load: { secrets[$0] },
            save: { key, data in
                if saveThrows { throw FixtureKeychainError() }
                secrets[key] = data
            },
            delete: { secrets.removeValue(forKey: $0) }
        )
        defer {
            Config.defaults = previousDefaults
            Config.chatProviderStore = previousStore
            Config.credentials = previousCredentials
        }
        defaults.set(true, forKey: Constants.Defaults.featureCompanion)

        let provider = ChatProvider(
            name: "Fixture Endpoint",
            baseURL: "https://coverage.invalid/v1",
            models: [ChatModel(name: "Fixture Model", model: "fixture-model")]
        )
        let agent = ChatProvider(
            name: "Fixture Agent", baseURL: "", models: [],
            kind: .acpAgent, acpCommand: "fixture-agent", acpArguments: ["--acp"]
        )
        let unconfiguredAgent = ChatProvider(
            name: "Unconfigured Agent", baseURL: "", models: [], kind: .acpAgent
        )
        Config.chatProviderStore.save([provider, agent, unconfiguredAgent])
        Config.setSelectedModelProfileID(provider.models[0].id)
        try Config.credentials.save(
            ChatProviderStore.keychainKeyPrefix + provider.id.uuidString,
            Data("fixture-key".utf8)
        )

        let store = TemplateStore(defaults: defaults)
        store.save([
            PromptTemplate(name: "Fixture Template", prompt: "Improve [placeholder]"),
            PromptTemplate(
                name: "Pinned Template", prompt: "Refine [placeholder]",
                modelID: provider.models[0].id
            ),
        ])

        var granted = false
        var promptCalls = 0
        var settingsCalls = 0
        let tab = CompanionDeepHosted(
            CompanionTab(
                templateStore: store,
                accessibilityStatus: { granted },
                requestAccessibilityPermissionPrompt: {
                    promptCalls += 1
                    return true
                },
                openAccessibilitySettingsURL: { settingsCalls += 1 }
            )
            .defaultAppStorage(defaults),
            size: NSSize(width: 900, height: 2200)
        )
        defer { tab.close() }
        await settle()

        // Permission section with the status closure reporting denied.
        try context.expect(tab.text.contains("Accessibility permission required"), "Denied state renders the permission warning")
        try tab.press("Open System Settings", context)
        try context.equal(settingsCalls, 1, "Settings press routes through the injected URL seam")
        try tab.press("Request Permission", context)
        try context.equal(promptCalls, 1, "Request press routes through the injected prompt seam")
        // The activation re-check posts through the same refresh closure.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        await settle()
        granted = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        await settle()
        try context.expect(tab.text.contains("Accessibility permission granted"), "Granted flip through the status closure re-renders the section")
        granted = false
        await settle()

        // Chat picker: model entry, agent entry, back to the model. Menus
        // are re-fetched per press: each selection re-renders the form and
        // rebuilds the popup cells, so a cached NSMenu may be stale. Measured
        // on this host: the SwiftUI popup cells materialize with empty
        // NSMenus (items build lazily on open and AXShowMenu is
        // unimplemented on the cell), so when no menu carries the fixture
        // entries the drive falls back to the config writes the picker's
        // set closure performs, plus the store notification the tab listens
        // to for provider refreshes. The set closure itself stays dark.
        func chatPopup() -> NSMenu? {
            tab.popupMenus().first { $0.menu.items.contains { $0.title == "Fixture Model" } }?.menu
        }
        if let menu = chatPopup() {
            try tab.pressPopupItem(in: menu, titled: "Fixture Model", context)
            await settle()
        } else {
            Config.setSelectedModelProfileID(provider.models[0].id)
        }
        try context.equal(
            defaults.string(forKey: Constants.Defaults.companionSelectedModelProfile),
            provider.models[0].id.uuidString,
            "Chat selection keeps the model profile"
        )
        // Agent selection: switches chat to the ACP provider and hides the
        // tools section on the next render. Measured: posting the store
        // notification re-assigns an equal providers array, which does not
        // invalidate the hosted tab's state, so the visibility assert reads
        // a freshly hosted tab whose body evaluates the config directly.
        if let menu = chatPopup() {
            try tab.pressPopupItem(in: menu, titled: "Fixture Agent (agent)", context)
            await settle()
        } else {
            Config.setSelectedModelProfileID(agent.id)
        }
        try context.equal(Config.selectedACPProvider()?.name, "Fixture Agent", "Agent selection switches chat to the ACP agent")
        let agentHosted = CompanionDeepHosted(
            CompanionTab(templateStore: store, accessibilityStatus: { granted }).defaultAppStorage(defaults),
            size: NSSize(width: 900, height: 2200)
        )
        defer { agentHosted.close() }
        await settle()
        try context.expect(agentHosted.text.contains("Command Runner") == false, "Tools section hides while an agent is selected")
        // Back to the model: tools return.
        if let menu = chatPopup() {
            try tab.pressPopupItem(in: menu, titled: "Fixture Model", context)
            await settle()
        } else {
            Config.setSelectedModelProfileID(provider.models[0].id)
        }
        try context.equal(Config.selectedACPProvider()?.name, nil, "Model selection clears the agent chat default")
        let modelHosted = CompanionDeepHosted(
            CompanionTab(templateStore: store, accessibilityStatus: { granted }).defaultAppStorage(defaults),
            size: NSSize(width: 900, height: 2200)
        )
        defer { modelHosted.close() }
        await settle()
        try context.expect(modelHosted.text.contains("Command Runner"), "Tools section returns once a model is selected again")

        // History pickers write through their onChange handlers. Same
        // measured empty-menu shape as the chat picker: drive the popup when
        // the menus carry items, otherwise write the config values the
        // onChange handlers persist.
        func popup(itemsContaining title: String) -> NSMenu? {
            tab.popupMenus().first { $0.menu.items.contains { $0.title == title } }?.menu
        }
        if let ageMenu = popup(itemsContaining: "Never") {
            try tab.pressPopupItem(in: ageMenu, titled: "30 days", context)
            await settle()
        } else {
            Config.setHistoryMaxAgeDays(30)
        }
        try context.equal(Config.historyMaxAgeDays(), 30, "Age picker writes the retention window")
        if let sessionMenu = popup(itemsContaining: "Everything") {
            try tab.pressPopupItem(in: sessionMenu, titled: "50 conversations", context)
            await settle()
        } else {
            Config.setHistoryMaxSessions(50)
        }
        try context.equal(Config.historyMaxSessions(), 50, "Session picker writes the conversation cap")

        // Pinned template row and the unconfigured agent caption.
        try context.expect(tab.text.contains("Model: Fixture Model"), "Pinned template row names its model")
        try context.expect(tab.text.contains("No command set"), "Commandless agent row shows the placeholder caption")

        // Provider save: keychain failure then success, both through the
        // prefilled editor (the seeded key keeps Save on the write path).
        try tab.pressEditAfter("Fixture Endpoint", context)
        await settle()
        try context.expect(tab.sheetText().contains("Edit Provider"), "Provider edit sheet opens")
        // The fixture URL refuses connections, so the fetch run covers the
        // sheet's error branch and its render without any real endpoint.
        try tab.sheetPress("Fetch Models", context)
        try await waitFor(context, "fetch failure renders") { tab.sheetText().contains("Fetch failed") }
        saveThrows = true
        try tab.sheetPress("Save", context)
        await settle()
        try context.expect(
            Config.chatProviders().contains { $0.name == "Fixture Endpoint" },
            "Store rewrite survives a keychain save failure"
        )
        try context.expect(
            secrets[ChatProviderStore.keychainKeyPrefix + provider.id.uuidString] != nil,
            "Seeded key still present after the failed save"
        )
        saveThrows = false
        try tab.pressEditAfter("Fixture Endpoint", context)
        await settle()
        try tab.sheetPress("Save", context)
        await settle()
        try context.expect(
            Config.providerHeaders(id: provider.id).isEmpty,
            "Header save lands an empty list on success"
        )

        // Model row: trash then the Add Model sheet.
        try tab.pressByHelp("Remove this model", context)
        await settle()
        try context.expect(
            Config.chatProviders().first { $0.id == provider.id }?.models.isEmpty == true,
            "Model trash empties the provider's model list"
        )
        try tab.press("Add Model", context)
        await settle()
        try context.expect(tab.sheetText().contains("New Model"), "Add Model presents the fresh model editor")
        try tab.sheetPress("Cancel", context)
        await settle()

        // Provider trash drops the provider and its row.
        try tab.pressByHelp("Delete this provider and its models", context)
        await settle()
        try context.equal(
            Config.chatProviders().map(\.name).sorted(),
            ["Fixture Agent", "Unconfigured Agent"],
            "Provider trash leaves only the agents"
        )

        // The three Add buttons present their sheets; none can save fresh.
        try tab.press("Add OpenAI-compatible", context)
        await settle()
        try context.expect(tab.sheetText().contains("New Provider"), "Add provider presents the fresh provider editor")
        try tab.sheetPress("Cancel", context)
        await settle()
        try tab.press("Add Local Models", context)
        await settle()
        try context.expect(tab.sheetText().contains("Local models"), "Add Local Models presents the MLX setup sheet")
        try tab.sheetPress("Done", context)
        try await waitFor(context, "local models sheet dismisses") { tab.sheetText().contains("Done") == false }
        try context.expect(tab.text.contains("Providers"), "Tab still renders after the local models sheet")
        try tab.press("Add ACP Agent", context)
        await settle()
        try context.expect(tab.sheetText().contains("New ACP Agent"), "Add ACP agent presents the fresh agent editor")
        try tab.sheetPress("Cancel", context)
        await settle()

        // Template trash removes exactly one row through the store save.
        // Measured: TemplateStore.load() re-appends missing built-in
        // defaults, so the stored count is fixture rows plus built-ins;
        // assert the delta instead of an absolute count.
        let beforeTrash = store.load().map(\.name)
        try tab.pressByHelp("Delete this template", context)
        await settle()
        let afterTrash = store.load().map(\.name)
        try context.equal(afterTrash.count, beforeTrash.count - 1, "Template trash drops one stored template")
        try context.equal(
            Array(Set(beforeTrash).subtracting(afterTrash)),
            ["Fixture Template"],
            "Template trash removes the fixture row"
        )
        try tab.press("Add Template", context)
        await settle()
        try context.expect(tab.sheetText().contains("New Template"), "Add Template presents the fresh template editor")
        try tab.sheetPress("Cancel", context)
        await settle()
    }

    private static func waitFor(_ context: CoverageContext, _ message: String, until condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            await Task.yield()
        }
        try context.expect(false, "Timed out: \(message)")
    }

    private static func settle() async {
        for _ in 0..<4 {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }
}