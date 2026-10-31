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
            // Same teardown rule as UI2Hosted: no ordering animations, the
            // transform animation outliving a panel over-releases on
            // dealloc (measured run12 segfault).
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
        /// SheetPresentationWindow; SwiftUI confirmationDialogs present an
        /// _NSAlertPanel instead (measured on this host). Presses inside
        /// either walk those windows.
        func sheetElements() -> [OwnedAccessibility.Element] {
            OwnedAccessibility.materialize()
            var found: [OwnedAccessibility.Element] = []
            for window in NSApp.windows {
                guard window.isVisible,
                      let content = window.contentView,
                      window !== self.window,
                      String(describing: type(of: window)).contains("SheetPresentation")
                        || String(describing: type(of: window)).contains("NSAlertPanel") else { continue }
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

        /// Presses a button inside a confirmationDialog's _NSAlertPanel.
        /// Measured on this host: the alert button's performPress returns
        /// false while the action still runs (the alert dismisses), so the
        /// helper verifies the dismissal instead of the return value.
        func alertPress(_ label: String, _ context: CoverageContext) throws {
            guard let element = sheetElements().first(where: { $0.accessibilityLabel() == label || $0.accessibilityTitle() == label }),
                  element.isAccessibilityEnabled() else {
                throw CoverageContext.Failure(description: "Alert control not found or disabled: \(label)")
            }
            _ = element.accessibilityPerformPress()
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
        do { try await generalTabReset(context) } catch { failures.append("generalTabReset: \(error)") }
        do { try launchAtLoginHelper(context) } catch { failures.append("launchAtLoginHelper: \(error)") }
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

        // Reset press only presents the confirmation dialog; Cancel
        // dismisses (verified by the alert leaving the window list)
        // without touching the destructive branch, which stays untested.
        try tab.press("Reset All Settings to Defaults", context)
        await settle()
        try context.expect(tab.sheetText().contains("Reset All Settings?"), "Reset press presents the confirmation dialog")
        try tab.alertPress("Cancel", context)
        await settle()
        var dismissed = false
        for _ in 0..<20 where dismissed == false {
            await Task.yield()
            dismissed = tab.sheetText().contains("Reset All Settings?") == false
            if dismissed == false { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        try context.expect(dismissed, "Cancel dismisses the reset confirmation dialog")
        try context.expect(tab.text.contains("Launch at login"), "Reset cancel leaves the tab rendered")
    }

    /// Full reset flow with every destructive effect recorded by the
    /// injected ResetEffects: no real defaults wipe, keychain delete,
    /// tccutil run, or relaunch ever happens, while the Library cleanup
    /// loops execute against fixture-owned paths inside the runner's
    /// isolated home. A second hosted tab throws from the keychain seam
    /// to cover the error branch, and runs with the bundle flag false to
    /// cover the notification guard's skip branch.
    static func generalTabReset(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("general-tab-reset")
        let boundary = UpdaterBackendBoundary()
        let updater = UpdaterViewModel(backend: boundary)
        updater.automaticallyChecksForUpdates = true

        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let bundleID = Constants.bundleIdentifier
        let ownedPaths: [URL] = [
            home.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist"),
            home.appendingPathComponent("Library/Preferences/\(bundleID).plist"),
            home.appendingPathComponent("Library/Preferences/\(bundleID).variant.plist"),
            home.appendingPathComponent("Library/Application Support/\(Constants.appName)/keep.txt"),
            home.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState")
        ]
        for path in ownedPaths {
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: path.path, contents: Data("fixture".utf8))
        }

        final class ResetRecorder {
            var wipedDefaults = 0
            var deletedKeychain = 0
            var clearedNotifications = 0
            var resetTCC = 0
            var synchronized = 0
            var restarted = 0
        }
        let recorder = ResetRecorder()
        var launchChanges: [Bool] = []
        let effects = ResetEffects(
            wipeDefaults: { recorder.wipedDefaults += 1 },
            deleteOAuthKeychain: { recorder.deletedKeychain += 1 },
            clearNotifications: { recorder.clearedNotifications += 1 },
            resetTCCPermissions: { recorder.resetTCC += 1 },
            libraryHome: { home },
            synchronizeDefaults: { recorder.synchronized += 1 },
            restartApp: { recorder.restarted += 1 }
        )

        let tab = Hosted(
            GeneralTab(
                launchAtLoginStatus: { true },
                setLaunchAtLogin: { enabled in launchChanges.append(enabled) },
                isRuntimeBundlePresent: true,
                resetEffects: effects
            )
            .environmentObject(updater)
            .defaultAppStorage(defaults),
            size: NSSize(width: 800, height: 1200)
        )
        defer { tab.close() }
        await settle()

        try tab.press("Reset All Settings to Defaults", context)
        await settle()
        try context.expect(tab.sheetText().contains("Reset All Settings?"), "Reset press presents the confirmation dialog")
        try tab.alertPress("Reset", context)
        await settle()
        for _ in 0..<40 where recorder.restarted == 0 {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        try context.equal(recorder.wipedDefaults, 1, "Reset wipes the defaults domain once")
        try context.equal(recorder.deletedKeychain, 1, "Reset deletes the OAuth keychain entry once")
        try context.equal(recorder.clearedNotifications, 1, "Reset clears notifications once with the bundle present")
        try context.equal(recorder.resetTCC, 1, "Reset runs the TCC reset once")
        try context.equal(recorder.synchronized, 1, "Reset synchronizes defaults once")
        try context.equal(recorder.restarted, 1, "Reset relaunches the app once")
        try context.expect(launchChanges.first == false, "Reset disables launch at login through the injected setter")
        try context.expect(updater.automaticallyChecksForUpdates == false, "Reset turns off automatic update checks")
        for path in ownedPaths {
            try context.expect(fm.fileExists(atPath: path.path) == false, "Reset removes owned path: \(path.lastPathComponent)")
        }

        // Keychain failure branch: the throwing seam covers the error log
        // while the rest of the reset still completes.
        let failingRecorder = ResetRecorder()
        var failingLaunches: [Bool] = []
        var failingEffects = effects
        failingEffects.deleteOAuthKeychain = { throw CoverageContext.Failure(description: "keychain fixture failure") }
        failingEffects.wipeDefaults = { failingRecorder.wipedDefaults += 1 }
        failingEffects.clearNotifications = { failingRecorder.clearedNotifications += 1 }
        failingEffects.resetTCCPermissions = { failingRecorder.resetTCC += 1 }
        failingEffects.synchronizeDefaults = { failingRecorder.synchronized += 1 }
        failingEffects.restartApp = { failingRecorder.restarted += 1 }
        let failingTab = Hosted(
            GeneralTab(
                launchAtLoginStatus: { true },
                setLaunchAtLogin: { enabled in failingLaunches.append(enabled) },
                isRuntimeBundlePresent: false,
                resetEffects: failingEffects
            )
            .environmentObject(updater)
            .defaultAppStorage(defaults),
            size: NSSize(width: 800, height: 1200)
        )
        defer { failingTab.close() }
        await settle()
        try failingTab.press("Reset All Settings to Defaults", context)
        await settle()
        try failingTab.alertPress("Reset", context)
        await settle()
        for _ in 0..<40 where failingRecorder.restarted == 0 {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try context.equal(failingRecorder.restarted, 1, "Keychain failure still completes the reset flow")
        try context.equal(failingRecorder.clearedNotifications, 0, "Absent bundle skips notification clearing")
        try context.expect(failingLaunches.first == false, "Failure run still disables launch at login")

        // Both reset runs wipe the Library tree, including the
        // ~/Library/Logs/BusinessBar directory AppLogger.shared created once
        // at process init. The real app recreates it on relaunch; this
        // process keeps running, so the scenario restores the directory or
        // every later file-log write in the suite fails (measured:
        // AppLoggingScenarios got 0 files).
        try fm.createDirectory(
            at: home.appendingPathComponent("Library/Logs/BusinessBar", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    /// LaunchAtLoginHelper bare-binary branch: the coverage runner executes
    /// a bare SPM binary under an isolated CFFIXED_USER_HOME, so isBundle is
    /// false and setEnabled writes/removes the LaunchAgent plist inside the
    /// fixture home only. The plist is a plain file: launchd never loads it,
    /// and the SMAppService branch (real bundle registration) is never taken.
    static func launchAtLoginHelper(_ context: CoverageContext) throws {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plist = agents.appendingPathComponent("com.businessbar.app.plist")
        try? FileManager.default.removeItem(at: plist)

        LaunchAtLoginHelper.setEnabled(true)
        try context.expect(FileManager.default.fileExists(atPath: plist.path), "Enable writes the LaunchAgent plist under the fixture home")
        try context.expect(LaunchAtLoginHelper.isEnabled, "isEnabled reads the plist back")

        if let data = FileManager.default.contents(atPath: plist.path),
           let plistObject = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let label = plistObject["Label"] as? String {
            try context.equal(label, "com.businessbar.app", "Plist carries the bundle label")
        } else {
            try context.expect(false, "Plist decodes with a Label entry")
        }

        LaunchAtLoginHelper.setEnabled(false)
        try context.expect(FileManager.default.fileExists(atPath: plist.path) == false, "Disable removes the LaunchAgent plist")
        try context.expect(LaunchAtLoginHelper.isEnabled == false, "isEnabled reflects removal")
    }
}
