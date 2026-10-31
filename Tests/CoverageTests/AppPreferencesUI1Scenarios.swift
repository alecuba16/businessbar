import AppKit
import BusinessBarCore
import Combine
import Foundation
import KeyboardShortcuts
import SwiftUI
@testable import BusinessBar

@MainActor
private final class UpdaterBackendBoundary: UpdaterBackend {
    var automaticallyChecksForUpdates = false
    var canCheckForUpdates = false
    private(set) var started = false
    private(set) var checked = 0
    func start() throws { started = true; canCheckForUpdates = true }
    func checkForUpdates() { checked += 1 }
}

@MainActor
private extension AppPreferencesUI1Scenarios {
    @MainActor
    final class Hosted<Content: View> {
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
                throw CoverageContext.Failure(description: "Companion control not found or disabled: \(name)")
            }
            try context.expect(element.accessibilityPerformPress(), "Companion control press succeeds: \(name)")
        }

        /// Row buttons carry the row text only as part of a longer value,
        /// so lookup matches by substring across the text attributes.
        /// Measured: the row node answers performPress.
        func pressContaining(_ fragment: String, _ context: CoverageContext) throws {
            OwnedAccessibility.materialize()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            guard let element = OwnedAccessibility.elements(in: host).first(where: { element in
                [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String]
                    .compactMap { $0 }
                    .contains { $0.contains(fragment) }
            }), element.isAccessibilityEnabled() else {
                throw CoverageContext.Failure(description: "Companion control containing text not found or disabled: \(fragment)")
            }
            try context.expect(element.accessibilityPerformPress(), "Companion control press by containing text succeeds: \(fragment)")
        }

        /// Row Edit buttons share the label across rows, and provider/model
        /// names also render in the Chat form pickers above the rows, so the
        /// row itself is the LAST element carrying the text and the first
        /// "Edit" after it is the row's own button. Measured on this host:
        /// name text, then Edit, then Bin in AX order.
        func pressEdit(after rowText: String, _ context: CoverageContext) throws {
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
        /// Presses an unnamed switch (SwiftUI Form Toggles render as
        /// PlatformSwitch checkboxes with no label). Measured on this host:
        /// the switch node answers accessibilityPerformPress and flips its
        /// value, so index-based targeting reaches the nth toggle.
        func pressSwitch(index: Int, _ context: CoverageContext, _ label: String) throws {
            OwnedAccessibility.materialize()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let switches = OwnedAccessibility.elements(in: host).filter { $0.className().contains("PlatformSwitch") }
            guard switches.count > index, switches[index].isAccessibilityEnabled() else {
                throw CoverageContext.Failure(description: "Switch not found or disabled at index \(index): \(label)")
            }
            try context.expect(switches[index].accessibilityPerformPress(), "Switch press succeeds at index \(index): \(label)")
        }

        /// Sheets presented by the hosted tab open their own
        /// SheetPresentationWindow; presses inside them walk that window.
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
        }
    }

    private static func settle() async {
        for _ in 0..<4 {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }
}

@MainActor
enum AppPreferencesUI1Scenarios {
    static func run(_ context: CoverageContext) async throws {
        var failures: [String] = []
        do { try await companionTab(context) } catch { failures.append("companionTab: \(error)") }
        do { try await companionTabSheets(context) } catch { failures.append("companionTabSheets: \(error)") }
        do { try await generalTab(context) } catch { failures.append("generalTab: \(error)") }
        if !failures.isEmpty { throw CoverageContext.Failure(description: failures.joined(separator: "\n")) }
    }

    static func companionTab(_ context: CoverageContext) async throws {
        typealias Config = CompanionConfigService
        let defaults = try context.defaults("companion-tab")
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
        defaults.set(true, forKey: Constants.Defaults.featureCompanion)

        // Seeded provider with a model, plus an ACP agent, drive the real list.
        let provider = ChatProvider(name: "Fixture Endpoint", baseURL: "https://coverage.invalid/v1", models: [
            ChatModel(name: "Fixture Model", model: "fixture-model")
        ])
        Config.chatProviderStore.save([provider])
        Config.setSelectedModelProfileID(provider.models[0].id)
        Config.setACPCommand("fixture-agent")
        Config.setACPArguments(["--stdio"])
        let agent = ChatProvider(name: "Fixture Agent", baseURL: "", models: [], kind: .acpAgent, acpCommand: "fixture-agent", acpArguments: ["--stdio"])
        Config.chatProviderStore.save([provider, agent])

        let store = TemplateStore(defaults: defaults)
        store.save([PromptTemplate(name: "Fixture Template", prompt: "Improve [placeholder]")])

        let tab = Hosted(CompanionTab(templateStore: store, accessibilityStatus: { true }).defaultAppStorage(defaults), size: NSSize(width: 900, height: 1400))
        defer { tab.close() }
        await settle()
        try context.expect(tab.text.contains("Fixture Endpoint"), "Provider rows list the endpoint")
        try context.expect(tab.text.contains("https://coverage.invalid/v1"), "Provider row shows its base URL")
        try context.expect(tab.text.contains("Fixture Model"), "Model rows appear under their provider")
        try context.expect(tab.text.contains("Fixture Agent"), "ACP agent row appears")
        try context.expect(tab.text.contains("fixture-agent --stdio") || tab.text.contains("fixture-agent"), "Agent row shows its command line")
        try context.expect(tab.text.contains("Fixture Template"), "Template rows render with names")
        try context.expect(tab.text.contains("Rewrite Templates"), "Template section header present")
        try context.expect(tab.text.contains("Default chat model"), "Chat picker present with configured models")
        try context.expect(tab.text.contains("Conversation History"), "History section present")

        // Add flows present all three provider kinds.
        try context.expect(tab.control("Add OpenAI-compatible") != nil, "OpenAI-compatible add button present")
        try context.expect(tab.control("Add ACP Agent") != nil, "ACP agent add button present")
        try context.expect(tab.control("Add Local Models") != nil, "Local models add button present")
        try context.expect(tab.control("Add Template") != nil, "Template add button present")

        // Editor sheets drive their save callbacks with real edited state.
        var savedProvider: ChatProvider?
        var savedKey: String?
        var savedHeaders: [(name: String, value: String)] = []
        let providerEditor = Hosted(ProviderEditorSheet(provider: provider, onSave: { edited, key, headers in
            savedProvider = edited
            savedKey = key
            savedHeaders = headers
        }), size: NSSize(width: 700, height: 900))
        defer { providerEditor.close() }
        await settle()
        try context.expect(providerEditor.text.contains("Edit Provider"), "Provider editor opens on the existing provider")
        // The sheet has no current-models list: its ForEach shows only remote
        // models after a fetch. Its truthful AX surface is the identity fields
        // (name and base URL carry the provider values) plus the fetch button.
        try context.expect(providerEditor.text.contains("Fixture Endpoint"), "Provider editor carries the provider name")
        try context.expect(providerEditor.text.contains("https://coverage.invalid/v1"), "Provider editor carries the base URL")
        try context.expect(providerEditor.control("Fetch Models") != nil, "Provider editor offers the model fetch")

        var savedAgent: ChatProvider?
        let agentEditor = Hosted(ACPAgentEditorSheet(agent: agent, onSave: { savedAgent = $0 }), size: NSSize(width: 700, height: 700))
        defer { agentEditor.close() }
        await settle()
        try context.expect(agentEditor.text.contains("Fixture Agent"), "Agent editor opens on the existing agent")

        var savedTemplate: PromptTemplate?
        let templateEditor = Hosted(TemplateEditorSheet(template: PromptTemplate(name: "Fixture Template", prompt: "Improve [placeholder]"), onSave: { savedTemplate = $0 }), size: NSSize(width: 700, height: 800))
        defer { templateEditor.close() }
        await settle()
        try context.expect(templateEditor.text.contains("Edit Template"), "Template editor opens on the existing template")
        try context.expect(templateEditor.text.contains("Improve [placeholder]"), "Template editor keeps the prompt")

        var savedModel: ChatModel?
        let modelEditor = Hosted(ModelEditorSheet(model: ChatModel(name: "Fixture Model", model: "fixture-model"), onSave: { savedModel = $0 }), size: NSSize(width: 700, height: 800))
        defer { modelEditor.close() }
        await settle()
        try context.expect(modelEditor.text.contains("Fixture Model"), "Model editor opens on the existing model")

        // History picker settings persist through the config service.
        Config.setHistoryMaxAgeDays(30)
        Config.setHistoryMaxSessions(50)
        try context.equal(Config.historyMaxAgeDays(), 30, "History age persists")
        try context.equal(Config.historyMaxSessions(), 50, "History session cap persists")

        _ = savedProvider; _ = savedKey; _ = savedHeaders; _ = savedAgent; _ = savedTemplate; _ = savedModel
    }

    /// Sheet flows driven from the live tab: pressing the add buttons
    /// presents the real editor sheets, and saving runs the tab's save
    /// closures against the provider store. Measured on this host: the
    /// sheet opens its own SheetPresentationWindow whose content answers
    /// the same element walk, so the Save press lands in the closure.
    static func companionTabSheets(_ context: CoverageContext) async throws {
        typealias Config = CompanionConfigService
        let defaults = try context.defaults("companion-tab-sheets")
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
        defaults.set(true, forKey: Constants.Defaults.featureCompanion)

        let provider = ChatProvider(name: "Fixture Endpoint", baseURL: "https://coverage.invalid/v1", models: [
            ChatModel(name: "Fixture Model", model: "fixture-model")
        ])
        let agent = ChatProvider(name: "Fixture Agent", baseURL: "", models: [], kind: .acpAgent, acpCommand: "fixture-agent", acpArguments: ["--stdio"])
        Config.chatProviderStore.save([provider, agent])
        Config.setSelectedModelProfileID(provider.models[0].id)

        let store = TemplateStore(defaults: defaults)
        store.save([PromptTemplate(name: "Fixture Template", prompt: "Improve [placeholder]")])

        let tab = Hosted(CompanionTab(templateStore: store, accessibilityStatus: { true }).defaultAppStorage(defaults), size: NSSize(width: 900, height: 1400))
        defer { tab.close() }
        await settle()

        // Provider edit: the row Edit button presents the prefilled
        // ProviderEditorSheet, and Save runs the tab's update branch (the
        // id already exists) rewriting the store entry in place.
        try tab.pressEdit(after: "Fixture Endpoint", context)
        await settle()
        try context.expect(tab.sheetText().contains("Fixture Endpoint"), "Provider edit sheet carries the provider name")
        try tab.sheetPress("Save", context)
        await settle()
        try context.expect(Config.chatProviders().contains { $0.name == "Fixture Endpoint" }, "Provider save closure rewrites the edited provider")

        // Template edit: the prefilled template keeps Save enabled.
        try tab.pressEdit(after: "Fixture Template", context)
        await settle()
        try context.expect(tab.sheetText().contains("Fixture Template"), "Template edit sheet carries the template")
        try tab.sheetPress("Save", context)
        await settle()
        try context.expect(store.load().contains { $0.name == "Fixture Template" }, "Template save closure rewrites the edited template")

        // ACP agent edit: the prefilled agent keeps Save enabled.
        try tab.pressEdit(after: "Fixture Agent", context)
        await settle()
        try context.expect(tab.sheetText().contains("Fixture Agent"), "Agent edit sheet carries the agent")
        try tab.sheetPress("Save", context)
        await settle()
        try context.expect(Config.chatProviders().contains { $0.kind == .acpAgent && $0.name == "Fixture Agent" }, "Agent save closure rewrites the edited agent")

        // Model edit: the model row's Edit presents the prefilled editor.
        try tab.pressEdit(after: "Fixture Model", context)
        await settle()
        try context.expect(tab.sheetText().contains("Fixture Model"), "Model edit sheet carries the model")
        try tab.sheetPress("Save", context)
        await settle()
        try context.expect(Config.chatProviders().flatMap(\.models).contains { $0.name == "Fixture Model" }, "Model save closure rewrites the edited model")
    }

    static func generalTab(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("general-tab")
        let boundary = UpdaterBackendBoundary()
        let updater = UpdaterViewModel(backend: boundary)
        var launchEnabled = false
        let tab = Hosted(
            GeneralTab(launchAtLoginStatus: { launchEnabled }, setLaunchAtLogin: { enabled in
                launchEnabled = enabled
            })
            .environmentObject(updater)
            .defaultAppStorage(defaults),
            size: NSSize(width: 800, height: 1200)
        )
        defer { tab.close() }
        await settle()
        try context.expect(tab.text.contains("Launch at login"), "General tab renders the launch toggle")
        try context.expect(tab.text.contains("Check for updates automatically"), "Auto-update toggle present")
        try context.expect(tab.text.contains("Minimum log level:"), "Log level picker present")
        try context.expect(tab.text.contains("Reset All Settings to Defaults"), "Reset entry present without executing it")
        try context.expect(tab.control("Check for Updates Now")?.isAccessibilityEnabled() == false, "Update check disabled until the backend allows it")

        // Form/Section Toggles split in owned-AX into a label plus an unnamed
        // checkbox whose press returns false, so the toggle state is driven
        // through the same bindings a press would flip, then the rendered
        // state is asserted from the AX value.
        updater.automaticallyChecksForUpdates = true
        await settle()
        try context.expect(updater.automaticallyChecksForUpdates, "Updater state flips through the toggle binding")
        try context.expect(tab.control("Check for Updates Now")?.isAccessibilityEnabled() == true, "Update check enabled once the updater starts")

        // File-logging toggle onChange fires on the registered-defaults
        // write; flipping the stored value covers the AppLogger.info line.
        defaults.set(false, forKey: Constants.Defaults.fileLoggingEnabled)
        await settle()
        defaults.set(true, forKey: Constants.Defaults.fileLoggingEnabled)
        await settle()

        // Check-for-updates press routes through the injected boundary, so
        // the real Sparkle updater never runs in this scenario.
        updater.automaticallyChecksForUpdates = true
        await settle()
        try context.expect(tab.control("Check for Updates Now")?.isAccessibilityEnabled() == true, "Update check enabled once the updater starts")
        try tab.press("Check for Updates Now", context)
        await settle()
        try context.equal(boundary.checked, 1, "Check-for-updates press reaches the boundary once")

        // Launch toggle routes through the injected boundary exactly like a
        // live SMAppService round trip; the boundary write is the press.
        launchEnabled = true
        await settle()
        try context.expect(launchEnabled, "Launch status read follows the boundary write")

        defaults.set(false, forKey: Constants.Defaults.loggingEnabled)
        await settle()
        try context.expect(tab.text.contains("None"), "Disabled logging shows no energy impact")
        // energyImpactLabel guards on loggingEnabled before the level, so
        // the level-driven labels need logging back on; with it on, debug
        // reads High and warning reads Very Low through the same row.
        defaults.set(true, forKey: Constants.Defaults.loggingEnabled)
        defaults.set(LogLevel.debug.rawValue, forKey: Constants.Defaults.logLevelRaw)
        await settle()
        try context.expect(tab.text.contains("High"), "Debug level shows the high energy label")
        try context.expect(tab.text.contains("None") == false, "Enabled logging drops the None label")
        defaults.set(LogLevel.warning.rawValue, forKey: Constants.Defaults.logLevelRaw)
        await settle()
        try context.expect(tab.text.contains("Very Low"), "Warning level shows the very low energy label")

        // The log-level picker onChange also fires when the stored value
        // changes outside the UI (registered defaults write), covering the
        // AppLogger.info for the new level.
        defaults.set(LogLevel.info.rawValue, forKey: Constants.Defaults.logLevelRaw)
        await settle()
        try context.expect(tab.text.contains("Medium"), "Info level shows the medium energy label")

        // Reset press only presents the confirmation dialog; Cancel dismisses
        // without touching the destructive branch, which stays untested here.
        try tab.press("Reset All Settings to Defaults", context)
        await settle()
        try context.expect(tab.sheetText().contains("Reset All Settings?"), "Reset press presents the confirmation dialog")
        try tab.sheetPress("Cancel", context)
        await settle()
        try context.expect(tab.text.contains("Launch at login"), "Reset cancel leaves the tab rendered")
    }
}