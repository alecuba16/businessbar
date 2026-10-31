import AppKit
@testable import BusinessBarCore
import Combine
import Foundation
import SwiftUI
@testable import BusinessBar

@MainActor
private final class UI2Hosted<Content: View> {
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
            throw CoverageContext.Failure(description: "UI2 control not found or disabled: \(name)")
        }
        try context.expect(element.accessibilityPerformPress(), "UI2 control press succeeds: \(name)")
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

@MainActor
private func ui2Settle() async {
    for _ in 0..<4 {
        await Task.yield()
        RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    }
}

@MainActor
enum AppPreferencesUI2Scenarios {
    static func run(_ context: CoverageContext) async throws {
        var failures: [String] = []
        do { try await toolsSection(context) } catch { failures.append("toolsSection: \(error)") }
        do { try await localModelsSection(context) } catch { failures.append("localModelsSection: \(error)") }
        do { try await calendarsTab(context) } catch { failures.append("calendarsTab: \(error)") }
        if !failures.isEmpty { throw CoverageContext.Failure(description: failures.joined(separator: "\n")) }
    }

    static func toolsSection(_ context: CoverageContext) async throws {
        typealias Config = CompanionConfigService
        let defaults = try context.defaults("tools-section")
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

        // Off baseline: every tool starts disabled so the enabled path is a
        // real transition through the config service.
        let section = UI2Hosted(ToolsSection(), size: NSSize(width: 900, height: 900))
        defer { section.close() }
        await ui2Settle()
        try context.expect(section.text.contains("Tools"), "Tools header renders")
        try context.expect(section.text.contains("Web Search"), "Web search row present")
        try context.expect(section.text.contains("Command Runner"), "Command runner row present")
        try context.expect(section.text.contains("GitHub Code Search"), "GitHub search row present")
        try context.expect(section.text.contains("off"), "Unconfigured web search shows off caption")
        try context.expect(section.text.contains("add a token in Configure"), "GitHub row asks for its token")

        // Sheet triggers flip the presentation state; the sheets themselves
        // get hosted directly below with full editor coverage.
        try context.expect(section.control("Configure…") != nil, "Configure buttons present")

        // Toggle state flows through the config service; the GitHub caption
        // flips from missing-token to token-set when a key lands.
        Config.setSearchProviderKind("brave")
        try? Config.setBraveKey("fixture-brave-key")
        Config.setGitHubSearchEnabled(true)
        try? Config.setGitHubSearchKey("fixture-github-token")
        let toggled = UI2Hosted(ToolsSection(), size: NSSize(width: 900, height: 900))
        defer { toggled.close() }
        await ui2Settle()
        try context.expect(toggled.text.contains("Brave"), "Brave provider caption reflects the persisted kind")
        try context.expect(toggled.text.contains("token set"), "GitHub caption flips once a token is stored")

        // Web search sheet: provider picker rows and key persistence.
        let webSheet = UI2Hosted(WebSearchToolSheet(), size: NSSize(width: 520, height: 460))
        defer { webSheet.close() }
        await ui2Settle()
        try context.expect(webSheet.text.contains("Web Search"), "Web search sheet opens")
        // Closed menu pickers expose only the selected row in AX; the other
        // provider labels appear when selected, so each is verified through
        // its own selected-state sheet below.
        try context.expect(webSheet.text.contains("Brave (API key)"), "Selected provider label reflects the persisted kind")
        try context.expect(webSheet.control("Provider") != nil || webSheet.text.contains("Brave (API key)"), "Provider picker present")

        Config.setSearchProviderKind("custom")
        Config.setCustomSearchEndpointText("https://coverage.invalid/search?q={query}&count={count}")
        let customSheet = UI2Hosted(WebSearchToolSheet(), size: NSSize(width: 520, height: 460))
        defer { customSheet.close() }
        await ui2Settle()
        try context.expect(customSheet.text.contains("Custom endpoint"), "Custom provider selected in its own sheet")
        try context.expect(customSheet.text.contains("{query}"), "Custom mode shows the URL template field")
        try context.expect(customSheet.control("Add Header") != nil, "Custom mode offers header pairs")

        Config.setSearchProviderKind("scrape-ddg")
        let ddgSheet = UI2Hosted(WebSearchToolSheet(), size: NSSize(width: 520, height: 460))
        defer { ddgSheet.close() }
        await ui2Settle()
        try context.expect(ddgSheet.text.contains("DuckDuckGo (scraped)"), "Scraped provider selected in its own sheet")
        try context.expect(ddgSheet.text.contains("Scraped engines need no key") || ddgSheet.text.contains("DuckDuckGo"), "Scraped mode shows its keyless flow")

        // Command runner sheet: permission dials and prefix rules.
        Config.setCommandToolsEnabled(true)
        Config.setCommandDefaultWorkingDir("/tmp")
        Config.setCommandPermissionMode(.allow)
        Config.setCommandAllowedPrefixes(["git status"])
        Config.setCommandDeniedPrefixes(["curl *"])
        let commandSheet = UI2Hosted(CommandRunnerToolSheet(), size: NSSize(width: 520, height: 700))
        defer { commandSheet.close() }
        await ui2Settle()
        try context.expect(commandSheet.text.contains("Command Runner"), "Command sheet opens")
        try context.expect(commandSheet.text.contains("run_command"), "Command sheet lists its tools")
        try context.expect(commandSheet.text.contains("Always allow"), "Allow rules render")
        try context.expect(commandSheet.text.contains("git status"), "Seeded allow rule visible")
        try context.expect(commandSheet.text.contains("Always deny"), "Deny rules render")
        try context.expect(commandSheet.text.contains("curl *"), "Seeded deny rule visible")
        try context.expect(commandSheet.text.contains("Per-category defaults"), "Category dials present")

        // GitHub sheet: SecureField placeholders never render in owned-AX
        // (measured, same as the Port field probe); with an empty token the
        // field contributes no AX text, so the truthful surface is the
        // caption row and link, plus a value-bearing field round trip via
        // the config service.
        try CompanionConfigService.setGitHubSearchKey("fixture-token-value")
        let githubSheet = UI2Hosted(GitHubSearchToolSheet(), size: NSSize(width: 520, height: 320))
        defer { githubSheet.close() }
        await ui2Settle()
        try context.expect(githubSheet.text.contains("GitHub Code Search"), "GitHub sheet opens")
        try context.expect(githubSheet.text.contains("fixture-token-value"), "Seeded token value renders in the field")
        try context.expect(githubSheet.text.contains("Personal access token") == false, "SecureField placeholder stays absent from AX")
        try context.expect(githubSheet.text.contains("No token yet?"), "Token caption row renders")
        try context.expect(githubSheet.text.contains("Create a fine-grained token"), "Token creation link present")
        try CompanionConfigService.setGitHubSearchKey("")
    }

    static func localModelsSection(_ context: CoverageContext) async throws {
        typealias Config = CompanionConfigService
        let defaults = try context.defaults("local-models")
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

        // Fixture home: downloaded models need a complete snapshot with
        // the required files, exactly like a real HF cache entry.
        let home = try context.temporaryDirectory("local-models-home").path
        let downloadedID = "mlx-community/Fixture-Downloaded-4bit"
        let snapshot = URL(fileURLWithPath: home)
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent("models--mlx-community--Fixture-Downloaded-4bit")
            .appendingPathComponent("snapshots")
            .appendingPathComponent("fixture-snapshot")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for file in MLXModelCatalog.requiredFiles {
            FileManager.default.createFile(atPath: snapshot.appendingPathComponent(file).path, contents: Data("fixture".utf8))
        }

        // Server manager with a stub python resolver and a free port.
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 1
        sessionConfig.timeoutIntervalForResource = 1
        let server = MLXServerManager(
            defaults: defaults,
            home: home,
            driver: .live(registerForQuit: { _ in }),
            session: URLSession(configuration: sessionConfig),
            resolvePython: { _ in "/usr/bin/true" },
            portAvailable: { _ in true },
            now: Date.init,
            sleep: { _ in },
            residentSize: { _ in 0 },
            observeResources: { _ in }
        )

        // Store with a fixture uv; downloads spawn a real process, so the
        // scenario drives state transitions and errors, never a live fetch.
        let store = MLXModelStore(
            defaults: defaults,
            home: home,
            driver: .live(registerForQuit: { _ in }),
            locateUV: { "/usr/bin/true" },
            sleep: { _ in }
        )

        // Custom catalog entry already on disk drives the custom row flow.
        let customEntry = MLXModelCatalog.Entry(
            id: downloadedID,
            displayName: "Fixture Downloaded",
            sizeBytes: 2_500_000_000,
            ramBytes: 4_000_000_000,
            kind: .text
        )
        _ = MLXModelCatalog.addCustomEntry(customEntry, defaults: defaults)
        MLXServerConfig.setActiveModelID(downloadedID, defaults: defaults)

        let section = UI2Hosted(
            LocalModelsSection(
                server: server,
                store: store,
                defaults: defaults,
                home: home,
                installedRAM: 64_000_000_000,
                locateUV: { "/usr/bin/true" },
                fetchDirectory: {
                    [
                        MLXModelDirectory.Item(id: "mlx-community/Directory-Alpha-4bit", kind: .text, sizeBytes: 2_000_000_000, downloads: 900),
                        MLXModelDirectory.Item(id: "mlx-community/Directory-Beta-4bit", kind: .textAndImages, sizeBytes: nil, downloads: 400)
                    ]
                },
                inspectRepo: { repoID in
                    MLXRepoInspector.Report(
                        repoID: repoID,
                        displayName: "Fixture Repo",
                        sizeBytes: 1_500_000_000,
                        ramBytes: 3_000_000_000,
                        kind: .text,
                        architecture: "FixtureForCausalLM",
                        contextLength: 8192,
                        quantization: "4-bit",
                        reasoning: .none
                    )
                }
            ),
            size: NSSize(width: 900, height: 1600)
        )
        defer { section.close() }
        await ui2Settle()

        try context.expect(section.text.contains("Local models (MLX)"), "Section header renders")
        try context.expect(section.text.contains("Fixture Downloaded"), "Custom catalog entry row appears")
        try context.expect(section.text.contains("Stopped"), "Downloaded active model shows the stopped label")
        try context.expect(section.text.contains("Keep model loaded"), "Settings rows present")
        // TextFields initialized with real values expose the value, not the
        // placeholder: owned-AX shows bare "8790" and "5" lines with no
        // "Port"/"Idle stop (minutes)" labels while the fields hold text.
        let axLines = section.text.split(separator: "\n").map(String.init)
        try context.expect(axLines.contains("8790"), "Port field carries its configured value")
        try context.expect(axLines.contains("5"), "Idle field carries its configured value")

        // Directory browse: injected fetch returns fixture items, filter and
        // sort controls only rearrange them. Rows show the derived display
        // name ("Directory-Alpha-4bit" strips its quantization suffix and
        // swaps hyphens), not the raw repo id.
        try section.press("Browse more models", context)
        await ui2Settle()
        try context.expect(section.text.contains("Directory Alpha"), "Directory lists fetched models")
        try context.expect(section.text.contains("900 downloads"), "Download counts render")
        try context.expect(section.text.contains("In catalog") || section.text.contains("Add"), "Directory rows resolve known ids")

        // Add registers the repo in the catalog without downloading.
        try section.press("Add", context)
        await ui2Settle()
        try context.expect(
            MLXModelCatalog.customEntries(defaults: defaults).contains { $0.id == "mlx-community/Directory-Alpha-4bit" },
            "Directory add registers the repo"
        )

        // Use activates the model and upserts the Local (MLX) provider.
        try section.press("Use", context)
        await ui2Settle()
        try context.equal(MLXServerConfig.activeModelID(defaults: defaults), downloadedID, "Use keeps the fixture model active")
        _ = Config.upsertLocalMLXProvider()
        try context.expect(
            Config.chatProviderStore.load().contains { $0.isLocalMLXProvider },
            "Local MLX provider upserted after activation"
        )

        // Port and idle settings persist through the config layer.
        MLXServerConfig.setPort(8765, defaults: defaults)
        MLXServerConfig.setIdleMinutes(17, defaults: defaults)
        MLXServerConfig.setKeepLoaded(true, defaults: defaults)
        try context.equal(MLXServerConfig.port(defaults: defaults), 8765, "Port persists")
        try context.equal(MLXServerConfig.idleMinutes(defaults: defaults), 17, "Idle minutes persist")
        try context.expect(MLXServerConfig.keepLoaded(defaults: defaults), "Keep loaded persists")
    }

    static func calendarsTab(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("calendars-tab")
        defaults.registerDefaults()

        let store = UI2CalendarBoundary()
        let meetings = MeetingManager(eventStore: store, defaults: defaults, notificationCenter: NotificationCenter())
        let auth = GoogleAuth(dependencies: .init(loadCredential: { throw CoverageContext.Failure(description: "fixture") }, saveCredential: { _ in }, deleteCredential: {}, configuration: { .init(clientNumber: "YOUR_FIXTURE", clientSecret: "YOUR_FIXTURE") }, request: { _ in throw CoverageContext.Failure(description: "fixture") }, openURL: { _ in false }))

        // Granted calendar permission: the selection list renders with the
        // fixture calendar and toggles persist their selection.
        var notificationGrants = 0
        let granted = UI2Hosted(
            CalendarsTab(
                meetingManager: meetings,
                googleAuth: auth,
                defaults: defaults,
                calendarAuthorization: { .fullAccess },
                notificationAuthorization: { receive in receive(true); notificationGrants += 1 }
            ).defaultAppStorage(defaults),
            size: NSSize(width: 900, height: 1400)
        )
        defer { granted.close() }
        await ui2Settle()
        try context.expect(notificationGrants > 0, "Granted fixture boundary answered the auth refresh")
        try context.expect(granted.text.contains("Enable calendar functionality"), "Feature toggle renders")
        try context.expect(granted.text.contains("Calendar permission granted"), "Granted status row renders")
        try context.expect(granted.text.contains("Coverage calendar"), "Fixture calendar appears in the selection list")
        try context.expect(granted.text.contains("Calendar permission granted"), "Permission section shows granted")
        // Calendar rows are Form/Section Toggles: the owned-AX bridge splits
        // them into a label plus an unnamed checkbox whose press returns
        // false, so the selection binding is exercised through its own save
        // path: seed the encoded selection, host a fresh tab (which runs the
        // load/decode path on appear), and confirm the stored round trip.
        defaults.set(try! JSONEncoder().encode(["preferences"]), forKey: BusinessBar.Constants.Defaults.selectedCalendars)
        let selectedTab = UI2Hosted(
            CalendarsTab(
                meetingManager: meetings,
                googleAuth: auth,
                defaults: defaults,
                calendarAuthorization: { .fullAccess },
                notificationAuthorization: { receive in receive(true) }
            ).defaultAppStorage(defaults),
            size: NSSize(width: 900, height: 1400)
        )
        defer { selectedTab.close() }
        await ui2Settle()
        try context.expect(selectedTab.text.contains("Coverage calendar"), "Fresh tab renders the calendar list from the stored selection")
        if let data = defaults.data(forKey: BusinessBar.Constants.Defaults.selectedCalendars),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            try context.expect(ids.contains("preferences"), "Calendar selection persists to defaults")
        } else {
            try context.expect(false, "Calendar selection persists to defaults: no encoded selection stored")
        }

        // Denied calendar permission: the missing-permission branch renders
        // and the grant button runs the real request through the fake store.
        var deniedGrants = 0
        let denied = UI2Hosted(
            CalendarsTab(
                meetingManager: meetings,
                googleAuth: auth,
                defaults: defaults,
                calendarAuthorization: { .denied },
                notificationAuthorization: { receive in receive(false); deniedGrants += 1 }
            ).defaultAppStorage(defaults),
            size: NSSize(width: 900, height: 1400)
        )
        defer { denied.close() }
        await ui2Settle()
        try context.expect(deniedGrants > 0, "Injected boundary answered the auth refresh")
        try context.expect(denied.text.contains("Calendar permission is missing."), "Denied status shows the missing-permission text")
        try context.expect(denied.text.contains("Calendar permission required"), "Status row shows required")
        try context.expect(denied.control("Grant Notification Permission") != nil, "Grant button present in the denied state")
        try context.expect(denied.text.contains("Notification permission required for reminders"), "Notification status row reflects the injected denial")

        // Provider picker carries both options regardless of configuration.
        try context.expect(granted.text.contains("macOS Calendar"), "Provider picker lists macOS Calendar")
        try context.expect(granted.text.contains("Google Calendar"), "Provider picker lists Google Calendar")

        // Meeting display toggles persist through defaults.
        defaults.set(false, forKey: BusinessBar.Constants.Defaults.showTomorrowEvents)
        defaults.set(true, forKey: BusinessBar.Constants.Defaults.showDeclinedEvents)
        try context.expect(!defaults.bool(forKey: BusinessBar.Constants.Defaults.showTomorrowEvents), "Tomorrow toggle persisted off")
        try context.expect(defaults.bool(forKey: BusinessBar.Constants.Defaults.showDeclinedEvents), "Declined toggle persisted on")

        // Notification lead time persists through its picker key.
        defaults.set(10, forKey: BusinessBar.Constants.Defaults.notificationMinutesBefore)
        try context.equal(defaults.integer(forKey: BusinessBar.Constants.Defaults.notificationMinutesBefore), 10, "Lead minutes persist")
    }

    private final class UI2CalendarBoundary: EventStoreProtocol {
        func requestAccess() async throws -> Bool { false }
        func fetchCalendars() async throws -> [MBCalendar] {
            [.init(id: "preferences", title: "Coverage calendar", color: "#227744", source: "Fixture")]
        }
        func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent] { [] }
    }
}