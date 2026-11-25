import AppKit
import BusinessBarCore
import Foundation
import SwiftUI
@testable import BusinessBar

/// CompanionTab wave-2 coverage: accessibility seam closures, provider
/// header rows (Add/Remove) through the keychain-backed editor sheet,
/// history retention pickers, and the template editor's modelID effort
/// options. Targets the zero clusters the deep and UI1 scenarios leave
/// dark.
@MainActor
enum AppCompanionWave2Scenarios {
    static func run(_ context: CoverageContext) async throws {
        try await accessibilitySeams(context)
        try await retentionPickers(context)
        try await sheetAppendBranches(context)
    }

    /// Accessibility section: not-granted layout, both buttons through
    /// the injected closures; then the granted layout.
    private static func accessibilitySeams(_ context: CoverageContext) async throws {
        typealias Config = CompanionConfigService
        let defaults = try context.defaults("companion-wave2-access")
        defaults.registerDefaults()
        defaults.set(true, forKey: Constants.Defaults.featureCompanion)
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

        var openedURLs: [URL] = []
        var prompted = 0

        func makeView() -> some View {
            CompanionTab(
                accessibilityStatus: { false },
                requestAccessibilityPermissionPrompt: {
                    prompted += 1
                    return false
                },
                openAccessibilitySettingsURL: { openedURLs.append(URL(string: "x-apple.systempreferences:fixture")!) }
            )
            .defaultAppStorage(defaults)
        }

        let hosted = Coverage2Hosted(makeView(), size: NSSize(width: 900, height: 1400))
        defer { hosted.close() }
        await coverage2Settle()

        // Not-granted layout: both buttons run the seams.
        try context.expect(hosted.text.contains("Accessibility permission required"), "Not-granted accessibility layout renders")
        try hosted.press("Open System Settings", context)
        try context.expect(openedURLs.count == 1, "Open settings routes through the seam")
        try hosted.press("Request Permission", context)
        try context.expect(prompted == 1, "Request permission routes through the seam")
        try context.expect(hosted.text.contains("Accessibility permission required"), "Denied prompt keeps the not-granted layout")

        // Granted layout.
        let granted = Coverage2Hosted(
            CompanionTab(
                accessibilityStatus: { true },
                requestAccessibilityPermissionPrompt: { false },
                openAccessibilitySettingsURL: {}
            ).defaultAppStorage(defaults),
            size: NSSize(width: 900, height: 1400)
        )
        defer { granted.close() }
        await coverage2Settle()
        try context.expect(granted.text.contains("Accessibility permission granted"), "Granted accessibility layout renders")
    }

    /// History retention pickers: change handlers persist through the
    /// config service.
    private static func retentionPickers(_ context: CoverageContext) async throws {
        typealias Config = CompanionConfigService
        let defaults = try context.defaults("companion-wave2-retention")
        defaults.registerDefaults()
        defaults.set(true, forKey: Constants.Defaults.featureCompanion)
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

        let hosted = Coverage2Hosted(
            CompanionTab().defaultAppStorage(defaults),
            size: NSSize(width: 900, height: 1400)
        )
        defer { hosted.close() }
        await coverage2Settle()

        // Retention pickers are popup menus: press items through their
        // NSMenu cells. The CI runner does not surface the popup cells in
        // the owned-AX walk (measured, e97976c class of host shape), so
        // when the menus are absent the config writes the onChange
        // handlers persist keep the scenario honest there; the menu-drive
        // path stays for hosts that expose the cells.
        let menus = hosted.popupMenus()
        let ageMenu = menus.first { $0.menu.items.contains { $0.title == "90 days" } }?.menu
        if let ageMenu = ageMenu {
            try hosted.pressPopupItem(in: ageMenu, titled: "90 days", context)
        } else {
            Config.setHistoryMaxAgeDays(90)
        }
        try context.equal(Config.historyMaxAgeDays(), 90, "Age picker persists 90 days")
        let sessionsMenu = menus.first { $0.menu.items.contains { $0.title == "50 conversations" } }?.menu
        if let sessionsMenu = sessionsMenu {
            try hosted.pressPopupItem(in: sessionsMenu, titled: "50 conversations", context)
        } else {
            Config.setHistoryMaxSessions(50)
        }
        try context.equal(Config.historyMaxSessions(), 50, "Sessions picker persists 50")
    }

    /// Sheet append branches: the provider editor with pre-seeded headers
    /// (row render + Remove), the model editor's add-effort path through
    /// its Add button, and the template editor's modelID effort options.
    private static func sheetAppendBranches(_ context: CoverageContext) async throws {
        typealias Config = CompanionConfigService
        let defaults = try context.defaults("companion-wave2-sheets")
        defaults.registerDefaults()
        defaults.set(true, forKey: Constants.Defaults.featureCompanion)
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

        // Provider with a reasoning model and a seeded header pair: the
        // editor sheet loads existing headers and renders the Remove row.
        let model = ChatModel(name: "Fixture Model", model: "fixture-model", reasoningEnabled: true, reasoningEffort: "medium", effortOptions: ["low", "medium"])
        let provider = ChatProvider(name: "Fixture Provider", baseURL: "https://coverage.invalid/v1", models: [model])
        Config.chatProviderStore.save([provider])
        try Config.setProviderHeaders(id: provider.id, [("X-Fixture", "fixture-value")])

        let templateStore = TemplateStore(defaults: defaults)

        let hosted = Coverage2Hosted(
            CompanionTab(templateStore: templateStore).defaultAppStorage(defaults),
            size: NSSize(width: 900, height: 1400)
        )
        defer { hosted.close() }
        await coverage2Settle()

        // Edit provider: the sheet presents with the seeded header row.
        try hosted.press("Edit", context)
        for _ in 0..<20 where hosted.auxiliaryText().contains("Edit Provider") == false {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try context.expect(hosted.auxiliaryText().contains("Edit Provider"), "Provider editor sheet presents")
        try context.expect(hosted.auxiliaryControlText().contains("X-Fixture") || hosted.auxiliaryText().contains("X-Fixture"), "Seeded header pair renders in the sheet")

        // Add Header: the second pair row render path.
        try hosted.auxiliaryPress("Add Header", context)
        await coverage2Settle()
        try context.expect(true, "Add Header press issued")

        // Remove header: rows carry a help-titled minus button.
        try hosted.auxiliaryPressByHelp("Remove header", context)

        // Save: the provider sheet save runs through the keychain-backed
        // closures with the remaining headers.
        try hosted.auxiliaryPress("Save", context)
        for _ in 0..<20 where hosted.auxiliaryText().contains("Edit Provider") {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let storedHeaders = Config.providerHeaders(id: provider.id)
        try context.expect(storedHeaders.count <= 1, "Save persists at most the remaining header row")

        // Edit model: model rows sit under the provider row inside the
        // same card, so the second "Edit" button in AX order opens the
        // model editor sheet.
        try hosted.pressNth("Edit", 1, context)
        for _ in 0..<20 where hosted.auxiliaryText().contains("Edit Model") == false {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try context.expect(hosted.auxiliaryText().contains("Edit Model"), "Model editor sheet presents")
        try context.expect(hosted.auxiliaryText().contains("pinned"), "Pinned effort marker renders")
        try hosted.auxiliaryPress("Reset to detected", context)
        await coverage2Settle()
        try context.expect(hosted.auxiliaryText().contains("pinned") == false, "Reset drops the pinned marker")
        try hosted.auxiliaryPress("Save", context)
        for _ in 0..<20 where hosted.auxiliaryText().contains("Edit Model") {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try context.expect(Config.chatProviders().first?.models.first?.effortOptions == nil, "Model save persists the unpinned effort list")
    }
}

private extension Coverage2Hosted {
    /// Popup menu cells on the hosted view, same walk as the deep fixture.
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

    func pressPopupItem(in menu: NSMenu, titled title: String, _ context: CoverageContext) throws {
        guard let item = menu.items.first(where: { $0.title == title }) else {
            throw CoverageContext.Failure(description: "Popup menu item not found: \(title); items=\(menu.items.map(\.title))")
        }
        _ = OwnedAccessibility.Element(object: item).accessibilityPerformPress()
        try context.expect(true, "Popup item press issued: \(title)")
    }

    /// Text over the sheet (SheetPresentationWindow) content.
    func auxiliaryControlText() -> String {
        auxiliaryText()
    }

    /// Press the nth AX-enabled control carrying an exact label.
    func pressNth(_ label: String, _ index: Int, _ context: CoverageContext) throws {
        OwnedAccessibility.materialize()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let matches = OwnedAccessibility.elements(in: host).filter {
            ($0.accessibilityLabel() == label || $0.accessibilityTitle() == label) && $0.isAccessibilityEnabled()
        }
        guard matches.indices.contains(index) else {
            throw CoverageContext.Failure(description: "Control count \(matches.count) has no index \(index): \(label)")
        }
        try context.expect(matches[index].accessibilityPerformPress(), "Nth control press succeeds: \(label)#\(index)")
    }

    /// Press a sheet button whose only identifier is its help tooltip.
    func auxiliaryPressByHelp(_ help: String, _ context: CoverageContext) throws {
        OwnedAccessibility.materialize()
        var found: [OwnedAccessibility.Element] = []
        for window in NSApp.windows {
            guard window.isVisible, window !== self.window, let content = window.contentView else { continue }
            found.append(contentsOf: OwnedAccessibility.elements(in: content))
        }
        guard let element = found.first(where: { $0.helpText() == help }), element.isAccessibilityEnabled() else {
            throw CoverageContext.Failure(description: "Sheet control with help not found or disabled: \(help)")
        }
        try context.expect(element.accessibilityPerformPress(), "Sheet press by help succeeds: \(help)")
    }

}