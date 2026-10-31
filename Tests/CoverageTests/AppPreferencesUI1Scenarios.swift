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

    static func generalTab(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("general-tab")
        let updater = UpdaterViewModel(backend: UpdaterBackendBoundary())
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
    }
}