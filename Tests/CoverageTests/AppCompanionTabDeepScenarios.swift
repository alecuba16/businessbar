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

    /// Writes into a TextField by placeholder. Measured on this host: the
    /// NSTextField-backed node persists the AX value into the SwiftUI
    /// binding, same as the composer.
    func setField(_ placeholder: String, _ text: String, _ context: CoverageContext) throws {
        OwnedAccessibility.materialize()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let all = OwnedAccessibility.elements(in: host)
        let fields = all.filter { $0.className().contains("NSTextField") }
        guard let field = fields.first(where: { element in
            let placeholderValue = element.objectValue.perform(NSSelectorFromString("accessibilityPlaceholderValue"))?.takeUnretainedValue() as? String
            return placeholderValue == placeholder
        }) else {
            throw CoverageContext.Failure(description: "Field with placeholder not found: \(placeholder); fields=\(fields.count)")
        }
        field.setAccessibilityText(text)
        try context.expect(true, "Field text set: \(placeholder)")
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
    let port: UInt16
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private let payload: Data

    init(payload: String) throws {
        self.payload = Data(payload.utf8)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        // Start first: no connection can be handled until the main run
        // loop spins, which only happens in the bind wait below, so the
        // handler can be attached after the members are initialized.
        listener.start(queue: .main)
        var spins = 0
        while listener.port == nil && spins < 500 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            spins += 1
        }
        let boundPort = listener.port?.rawValue ?? 0
        guard boundPort != 0 else { throw CoverageContext.Failure(description: "Stub server failed to bind") }
        self.listener = listener
        self.port = boundPort
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
    }

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)
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

        // Header rows: Add Header covers the pair row render path.
        try editor.press("Add Header", context)
        await settle()
        try context.expect(editor.text.contains("Header name"), "Added header pair row renders")

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

    /// Model editor effort options: Add pins the parsed list, Reset to
    /// detected un-pins, and a stored non-preset value reveals the custom
    /// field.
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

        // Add effort value: parseList turns the comma list into pinned rows.
        try editor.setField("Add effort value", "turbo, eco", context)
        try editor.press("Add", context)
        await settle()
        try context.expect(editor.text.contains("pinned"), "Adding pins the derived vocabulary")
        try context.expect(editor.text.contains("turbo"), "Added turbo appears in the list")

        try editor.press("Save", context)
        await settle()
        try context.equal(saved?.effortOptions, ["none", "low", "medium", "high", "xhigh", "max", "turbo", "eco"], "Save writes the pinned effort list")
        try context.equal(saved?.reasoningEffort, "medium", "Preset selection persists")

        // Custom effort: a stored non-preset value opens the custom field.
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
        try context.expect(custom.text.contains("Custom effort value"), "Non-preset stored effort reveals the custom field")
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
        try context.expect(custom.text.contains("Custom effort value"), "Non-preset stored effort reveals the custom field")
        try custom.press("Save", context)
        await settle()
        try context.equal(customSaved?.reasoningEffort, "ultra", "Custom effort value saves unchanged")
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