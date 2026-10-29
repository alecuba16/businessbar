import BusinessBarCore
import KeyboardShortcuts
import SwiftUI

/// Tracks the Accessibility permission state for the Companion UI, the
/// same trust signal the Badges tab uses. Re-checks when the app becomes
/// active so a grant in System Settings shows up on return.
@MainActor
private final class AccessibilityPermissionModel: ObservableObject {
    @Published private(set) var isGranted = AXIsProcessTrusted()

    func refresh() {
        isGranted = AXIsProcessTrusted()
    }
}

// MARK: - CompanionTab

/// Preferences tab for the LLM Companion: enable/disable, shortcuts,
/// provider configuration and prompt templates.
struct CompanionTab: View {
    @AppStorage(Constants.Defaults.featureCompanion) private var companionEnabled = true
    @StateObject private var accessibilityPermission = AccessibilityPermissionModel()

    @State private var historyMaxAgeDays: Int
    @State private var historyMaxSessions: Int
    @State private var templates: [PromptTemplate]
    /// Item-based sheet presentation: each edit target re-inits the editor.
    /// The old isPresented + separate editing state raced the dismiss
    /// animation, so a quick reopen kept the previous template's values.
    @State private var editingTemplate: PromptTemplate?
    @State private var keychainError: String?
    @State private var providers: [ChatProvider]
    @State private var editingProvider: ChatProvider?
    @State private var editingACPProvider: ChatProvider?
    @State private var editingModel: EditingModelTarget?
    @State private var showsLocalModels = false

    private let templateStore = TemplateStore()

    init() {
        _historyMaxAgeDays = State(initialValue: CompanionConfigService.historyMaxAgeDays())
        _historyMaxSessions = State(initialValue: CompanionConfigService.historyMaxSessions())
        _templates = State(initialValue: TemplateStore().load())
        _providers = State(initialValue: CompanionConfigService.chatProviders())
    }

    var body: some View {
        Form {
            // MARK: Feature
            Section {
                Toggle("Enable Companion", isOn: $companionEnabled)
            } footer: {
                Text("Adds an AI chat panel and rewrite shortcuts for selected text. Off removes all shortcuts and panels.")
            }

            if companionEnabled {
                // MARK: Shortcuts
                Section {
                    KeyboardShortcuts.Recorder("Toggle chat panel:", name: .toggleCompanionChat)
                } header: {
                    Text("Keyboard Shortcuts")
                } footer: {
                    Text("The chat panel shortcut is predefined. Rewrite templates get their own shortcut below.")
                }

                // MARK: Default chat model
                // Agents count too: an agents-only setup still needs the
                // picker to select one.
                if providers.contains(where: { !$0.models.isEmpty || $0.kind == .acpAgent }) {
                    Section {
                        Picker("Default chat model", selection: Binding(
                            get: { () -> UUID? in
                                // The stored selection may point at an agent;
                                // the picker then shows the agent entry so the
                                // current state stays visible.
                                if let agent = CompanionConfigService.selectedACPProvider() {
                                    return agent.id
                                }
                                return CompanionConfigService.selectedModel()?.model.id
                            },
                            set: { (newValue: UUID?) in
                                if let newValue {
                                    CompanionConfigService.setSelectedModelProfileID(newValue)
                                    providers = CompanionConfigService.chatProviders()
                                }
                            }
                        )) {
                            ForEach(providers) { provider in
                                if provider.kind == .acpAgent {
                                    Text(provider.name + " (agent)").tag(Optional(provider.id))
                                } else {
                                    Section(provider.name) {
                                        ForEach(provider.models) { model in
                                            Text(model.name).tag(Optional(model.id))
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Chat")
                    } footer: {
                        Text("Used by the chat panel and rewrite shortcuts when no per-message model is picked. Picking an ACP agent switches chat to that agent.")
                    }
                }

                // MARK: Providers
                Section {
                    ForEach(providers) { provider in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.name)
                                        .fontWeight(.medium)
                                    Text(provider.kind == .acpAgent
                                         ? agentCommandLine(provider)
                                         : provider.baseURL)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(provider.kind.label)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .clipShape(Capsule())
                                Button("Edit") {
                                    if provider.kind == .acpAgent {
                                        editingACPProvider = provider
                                    } else {
                                        editingProvider = provider
                                    }
                                }
                                .controlSize(.small)
                                Button {
                                    CompanionConfigService.deleteProvider(id: provider.id)
                                    providers = CompanionConfigService.chatProviders()
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Delete this provider and its models")
                            }

                            if provider.kind != .acpAgent {
                                ForEach(provider.models) { model in
                                    HStack {
                                        Text(model.name)
                                            .lineLimit(1)
                                        Spacer()
                                        if CompanionConfigService.selectedModel()?.model.id == model.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.accentColor)
                                                .help("Selected for chat")
                                        }
                                        Button("Edit") {
                                            editingModel = EditingModelTarget(provider: provider, model: model)
                                        }
                                        .controlSize(.small)
                                        Button {
                                            CompanionConfigService.deleteModel(id: model.id, in: provider.id)
                                            providers = CompanionConfigService.chatProviders()
                                        } label: {
                                            Image(systemName: "minus.circle")
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove this model")
                                    }
                                    .padding(.leading, 12)
                                }

                                Button("Add Model") {
                                    editingModel = EditingModelTarget(provider: provider, model: ChatModel(name: "", model: ""))
                                }
                                .controlSize(.small)
                                .padding(.leading, 12)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    HStack {
                        Button("Add OpenAI-compatible") {
                            // Item-based sheets present only non-nil items,
                            // so Add passes a fresh provider instead of nil.
                            editingProvider = ChatProvider(name: "", baseURL: "", models: [])
                        }
                        Button("Add Local Models") {
                            showsLocalModels = true
                        }
                        Button("Add ACP Agent") {
                            editingACPProvider = ChatProvider(
                                name: "",
                                baseURL: "",
                                models: [],
                                kind: .acpAgent
                            )
                        }
                    }
                } header: {
                    Text("Providers")
                } footer: {
                    Text("Three kinds: OpenAI-compatible endpoints with their own key and models, the on-device Local MLX server (Add Local Models opens its setup), and ACP agents over stdio. The checkmark marks the chat default; picking an ACP agent in the Chat picker switches the panel to it.")
                }

                // MARK: Search
                // Tools apply to OpenAI-compatible endpoints; ACP agents
                // negotiate their own capabilities.
                if CompanionConfigService.selectedACPProvider() == nil {
                    ToolsSection()
                }

                // MARK: Templates
                Section {
                    ForEach($templates) { $template in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                    .fontWeight(.medium)
                                if template.action != .overlay {
                                    Text(template.action.label)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(template.prompt)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                if let modelName = pinnedModelName(template.modelID) {
                                    Text(modelName)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            KeyboardShortcuts.Recorder(for: .rewriteTemplate(template.id))
                                .fixedSize()
                            Button("Edit") {
                                editingTemplate = template
                            }
                            .controlSize(.small)
                            Button {
                                templates.removeAll { $0.id == template.id }
                                templateStore.save(templates)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Delete this template")
                        }
                    }

                    Button("Add Template") {
                        editingTemplate = PromptTemplate(name: "", prompt: "[placeholder]")
                    }
                } header: {
                    Text("Rewrite Templates")
                } footer: {
                    Text("Use [placeholder] where the selected text goes. Assign a shortcut to a template to run that rewrite on the selection from any app. Wrap the reply in <output></output> tags in your prompt and only that text is used, with no model commentary. Replace selection swaps the selection in place when the reply carries the tags; insert after keeps the selection and adds the reply right after it. Both fall back to the overlay when direct writing is not possible.")
                }

                // MARK: History
                Section {
                    Picker("Delete conversations older than", selection: $historyMaxAgeDays) {
                        Text("Never").tag(0)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .onChange(of: historyMaxAgeDays) { _, newValue in
                        CompanionConfigService.setHistoryMaxAgeDays(newValue)
                    }

                    Picker("Keep at most", selection: $historyMaxSessions) {
                        Text("Everything").tag(0)
                        Text("20 conversations").tag(20)
                        Text("50 conversations").tag(50)
                        Text("100 conversations").tag(100)
                    }
                    .onChange(of: historyMaxSessions) { _, newValue in
                        CompanionConfigService.setHistoryMaxSessions(newValue)
                    }
                } header: {
                    Text("Conversation History")
                } footer: {
                    Text("Cleanup runs when the app starts and after each saved reply. The history drawer in the chat panel can also delete sessions by age or all at once.")
                }

                // MARK: Accessibility Permission
                Section("Accessibility Permission") {
                    if accessibilityPermission.isGranted {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Accessibility permission granted")
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Accessibility permission required")
                                    .font(.headline)
                            }

                            Text("BusinessBar needs Accessibility access to read the selected text for rewrites triggered by the template shortcuts.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 10) {
                                Button("Open System Settings") {
                                    openAccessibilitySettings()
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Request Permission") {
                                    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                                    _ = AXIsProcessTrustedWithOptions(options)
                                    accessibilityPermission.refresh()
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.top, 2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding()
        // Re-check whenever the app comes back to front, so a grant made
        // in System Settings is reflected immediately on return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityPermission.refresh()
        }
        // Store writes from outside this tab (shortcut sync, migrations)
        // must not be clobbered by a save from the tab's stale copy.
        .onReceive(NotificationCenter.default.publisher(for: TemplateStore.didChangeNotification)) { _ in
            templates = templateStore.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: ChatProviderStore.didChangeNotification)) { _ in
            providers = CompanionConfigService.chatProviders()
        }
        .sheet(item: $editingTemplate) { template in
            TemplateEditorSheet(template: template) { saved in
                if let index = templates.firstIndex(where: { $0.id == saved.id }) {
                    templates[index] = saved
                } else {
                    templates.append(saved)
                }
                templateStore.save(templates)
                editingTemplate = nil
            }
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditorSheet(provider: provider) { saved, apiKey, headers in
                if let index = providers.firstIndex(where: { $0.id == saved.id }) {
                    providers[index] = saved
                } else {
                    providers.append(saved)
                }
                CompanionConfigService.chatProviderStore.save(providers)
                if !apiKey.isEmpty {
                    do {
                        try CompanionConfigService.setProviderAPIKey(saved.id, apiKey)
                        keychainError = nil
                    } catch {
                        keychainError = "Could not save the API key: \(error.localizedDescription)"
                    }
                }
                do {
                    try CompanionConfigService.setProviderHeaders(id: saved.id, headers)
                } catch {
                    keychainError = "Could not save the headers: \(error.localizedDescription)"
                }
                editingProvider = nil
            }
        }
        .sheet(item: $editingModel) { target in
            ModelEditorSheet(model: target.model) { saved in
                if let providerIndex = providers.firstIndex(where: { $0.id == target.provider.id }) {
                    if let modelIndex = providers[providerIndex].models.firstIndex(where: { $0.id == saved.id }) {
                        providers[providerIndex].models[modelIndex] = saved
                    } else {
                        providers[providerIndex].models.append(saved)
                    }
                    CompanionConfigService.chatProviderStore.save(providers)
                }
                editingModel = nil
            }
        }
        .sheet(isPresented: $showsLocalModels, onDismiss: {
            providers = CompanionConfigService.chatProviders()
        }) {
            LocalModelsSheet()
        }
        .sheet(item: $editingACPProvider) { agent in
            ACPAgentEditorSheet(agent: agent) { saved in
                if let index = providers.firstIndex(where: { $0.id == saved.id }) {
                    providers[index] = saved
                } else {
                    providers.append(saved)
                }
                CompanionConfigService.chatProviderStore.save(providers)
                editingACPProvider = nil
            }
        }
    }

    /// Display name for a template's pinned model, nil when the template
    /// follows the default chat model or the pinned id no longer resolves.
    private func pinnedModelName(_ modelID: UUID?) -> String? {
        guard let modelID,
              let provider = providers.first(where: { $0.model(id: modelID) != nil }),
              let model = provider.model(id: modelID) else { return nil }
        return "Model: \(model.name)" + (provider.kind == .localMLX ? " (local)" : "")
    }

    /// One-line command line for an agent row: command plus arguments, or a
    /// placeholder while the agent is not configured yet.
    private func agentCommandLine(_ provider: ChatProvider) -> String {
        guard !provider.acpCommand.isEmpty else { return "No command set" }
        return ([provider.acpCommand] + provider.acpArguments).joined(separator: " ")
    }

    /// Opens System Settings to the Accessibility privacy pane, the same
    /// destination the Badges tab uses.
    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - EditingModelTarget

/// Identifiable wrapper for the model editor's edit target. The sheet is
/// item-based, so the tuple needed a stable identity for SwiftUI.
struct EditingModelTarget: Identifiable {
    let provider: ChatProvider
    let model: ChatModel
    var id: UUID { model.id }
}

// MARK: - ProviderEditorSheet

/// Sheet for creating and editing a provider: name, endpoint, per-provider
/// API key and request headers. Models are managed in the list below the
/// provider row.
struct ProviderEditorSheet: View {
    @State private var provider: ChatProvider
    @State private var apiKey: String
    @State private var headers: [EditableHeaderPair]
    @State private var fetchedModels: [CompanionConfigService.RemoteModelInfo]?
    @State private var fetchError: String?
    @State private var isFetchingModels = false
    let onSave: (ChatProvider, String, [(name: String, value: String)]) -> Void

    @Environment(\.dismiss) private var dismiss

    init(provider: ChatProvider?, onSave: @escaping (ChatProvider, String, [(name: String, value: String)]) -> Void) {
        let initial = provider ?? ChatProvider(name: "", baseURL: "", models: [])
        _provider = State(initialValue: initial)
        _apiKey = State(initialValue: CompanionConfigService.providerAPIKey(id: initial.id))
        _headers = State(initialValue: CompanionConfigService.providerHeaders(id: initial.id).map {
            EditableHeaderPair(name: $0.name, value: $0.value)
        })
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(provider.name.isEmpty ? "New Provider" : "Edit Provider")
                .font(.headline)

            TextField("Name", text: $provider.name)
            TextField("Base URL (ends in /v1)", text: $provider.baseURL)
            if provider.kind != .localMLX {
                SecureField("API Key (stored in Keychain)", text: $apiKey)
            }

            ForEach($headers) { $pair in
                HStack {
                    TextField("Header name", text: $pair.name)
                    SecureField("Value", text: $pair.value)
                    Button {
                        headers.removeAll { $0.id == pair.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove header")
                }
            }
            Button("Add Header") {
                headers.append(EditableHeaderPair(name: "", value: ""))
            }

            HStack {
                Button {
                    isFetchingModels = true
                    fetchError = nil
                    let trimmedHeaders = headers
                        .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                        .map { (name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value) }
                    Task {
                        do {
                            fetchedModels = try await CompanionConfigService.fetchRemoteModels(
                                baseURL: provider.baseURL,
                                apiKey: apiKey,
                                headers: trimmedHeaders
                            )
                        } catch {
                            fetchedModels = nil
                            fetchError = error.localizedDescription
                        }
                        isFetchingModels = false
                    }
                } label: {
                    if isFetchingModels {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Fetch Models")
                    }
                }
                .disabled(provider.baseURL.isEmpty || isFetchingModels)
                .help("Fetch the model list from the provider's /models endpoint")
                if let fetchedModels, !fetchedModels.isEmpty {
                    Text("\(fetchedModels.count) models")
                        .foregroundColor(.secondary)
                }
                if let fetchError {
                    Text("Fetch failed: \(fetchError)")
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }
            if let fetchedModels, !fetchedModels.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(fetchedModels) { info in
                            Text(info.id)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(info.supportsReasoning ? .primary : .secondary)
                        }
                    }
                }
                .frame(maxHeight: 120)
                .frame(maxWidth: .infinity, alignment: .leading)
                .border(Color.secondary.opacity(0.3))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let trimmed = headers
                        .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                        .map { (name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value) }
                    onSave(provider, apiKey, trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(provider.name.isEmpty || provider.baseURL.isEmpty)
            }
        }
        .frame(width: 420, height: 480)
        .padding()
    }
}

/// Identifiable header pair for editor rows (providers, custom search).
struct EditableHeaderPair: Identifiable {
    var id = UUID()
    var name: String
    var value: String
}

// MARK: - ACPAgentEditorSheet

/// Sheet for one ACP agent provider: display name plus the stdio command
/// line. The process starts with the chat panel and stops when it closes.
struct ACPAgentEditorSheet: View {
    @State private var agent: ChatProvider
    @State private var argumentsText: String
    let onSave: (ChatProvider) -> Void

    @Environment(\.dismiss) private var dismiss

    init(agent: ChatProvider, onSave: @escaping (ChatProvider) -> Void) {
        var initial = agent
        initial.kind = .acpAgent
        _agent = State(initialValue: initial)
        _argumentsText = State(initialValue: initial.acpArguments.joined(separator: " "))
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(agent.name.isEmpty ? "New ACP Agent" : "Edit ACP Agent")
                .font(.headline)

            TextField("Name", text: $agent.name)
            TextField("Command, for example gemini", text: $agent.acpCommand)
            TextField("Arguments, space separated, for example --acp", text: $argumentsText)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    // A trailing space would break the subprocess spawn, so
                    // the command line is trimmed before it is stored.
                    agent.name = agent.name.trimmingCharacters(in: .whitespaces)
                    agent.acpCommand = agent.acpCommand.trimmingCharacters(in: .whitespaces)
                    agent.acpArguments = argumentsText
                        .split(whereSeparator: { $0.isWhitespace })
                        .map(String.init)
                    onSave(agent)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    agent.name.trimmingCharacters(in: .whitespaces).isEmpty
                        || agent.acpCommand.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .frame(width: 420)
        .padding()
    }
}

// MARK: - ModelEditorSheet

/// Sheet for one model inside a provider: display name, model string,
/// system prompt, and the Reasoning checkbox gating the effort picker.
struct ModelEditorSheet: View {
    @State private var model: ChatModel
    let onSave: (ChatModel) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Picker selection: "__custom__" reveals the custom effort text field;
    /// non-preset stored values keep it selected on open.
    @State private var effortSelection: String
    @State private var customEffort: String

    /// Effort values offered for this model: pinned options first, then
    /// name-pattern fallback, then the global list.
    private var modelEffortOptions: [String] {
        CompanionConfigService.effortOptions(forModel: model)
    }

    init(model: ChatModel, onSave: @escaping (ChatModel) -> Void) {
        _model = State(initialValue: model)
        let stored = model.reasoningEffort ?? ""
        _effortSelection = State(initialValue:
            CompanionConfigService.effortLevels.contains(stored) || stored.isEmpty
                ? stored : "__custom__")
        _customEffort = State(initialValue: stored)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.name.isEmpty ? "New Model" : "Edit Model")
                .font(.headline)

            TextField("Name", text: $model.name)
            TextField("Model string, for example gpt-4o-mini", text: $model.model)
            TextField("System prompt (optional)", text: Binding(
                get: { model.systemPrompt ?? "" },
                set: { model.systemPrompt = $0.isEmpty ? nil : $0 }
            ), axis: .vertical)
                .lineLimit(2...4)

            Toggle("Text", isOn: Binding(
                get: { model.acceptsText ?? true },
                set: { model.acceptsText = $0 }
            ))
            Toggle("Images", isOn: Binding(
                get: { model.acceptsImages ?? false },
                set: { model.acceptsImages = $0 }
            ))

            Toggle("Reasoning", isOn: Binding(
                get: { model.reasoningEnabled ?? false },
                set: { model.reasoningEnabled = $0 }
            ))

            if model.reasoningEnabled == true {
                Picker("Effort", selection: $effortSelection) {
                    ForEach(modelEffortOptions, id: \.self) { level in
                        Text(level.capitalized).tag(level)
                    }
                    Text("Custom").tag("__custom__")
                }
                if effortSelection == "__custom__" {
                    TextField("Custom effort value", text: $customEffort)
                }

                HStack {
                    Text("Effort options")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(modelEffortOptions.joined(separator: " \u{2022}"))
                        .foregroundColor(.secondary)
                        .help("Values this model accepts. Detected from the model name or provider model list; pin them below to override.")
                }
                TextField(
                    "Comma-separated effort values, for example low,medium,high",
                    text: Binding(
                        get: {
                            model.effortOptions?.joined(separator: ",") ?? ""
                        },
                        set: {
                            let parts = $0
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            model.effortOptions = parts.isEmpty ? nil : parts
                        }
                    )
                )
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if model.reasoningEnabled == true {
                        model.reasoningEffort = effortSelection == "__custom__"
                            ? customEffort
                            : effortSelection
                    } else {
                        model.reasoningEffort = nil
                    }
                    onSave(model)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.name.isEmpty || model.model.isEmpty)
            }
        }
        .frame(width: 420, height: 430)
        .padding()
    }
}

// MARK: - TemplateEditorSheet

struct TemplateEditorSheet: View {
    @State var template: PromptTemplate
    let onSave: (PromptTemplate) -> Void

    /// Picker selection for the effort row: "default" maps to nil, "custom"
    /// reveals the text field; preset levels write straight into the template.
    @State private var effortSelection: String
    @State private var customEffort: String

    @Environment(\.dismiss) private var dismiss

    private static let presetLevels = CompanionConfigService.effortLevels

    /// Effort values for the model the template pins; the default chat
    /// model applies when none is pinned. A stored preset that the resolved
    /// list lacks still shows, so the picker keeps a matching tag.
    private var templateEffortOptions: [String] {
        var options: [String]
        if let modelID = template.modelID {
            options = CompanionConfigService.effortOptions(forModelID: modelID)
        } else if let selected = CompanionConfigService.selectedModel() {
            options = CompanionConfigService.effortOptions(forModel: selected.model, provider: selected.provider)
        } else {
            options = Self.presetLevels
        }
        if let stored = template.reasoningEffort,
           !stored.isEmpty,
           Self.presetLevels.contains(stored),
           !options.contains(stored) {
            options.append(stored)
        }
        return options
    }

    init(template: PromptTemplate?, onSave: @escaping (PromptTemplate) -> Void) {
        let initial = template ?? PromptTemplate(name: "", prompt: "[placeholder]")
        _template = State(initialValue: initial)
        let stored = initial.reasoningEffort ?? ""
        if stored.isEmpty {
            _effortSelection = State(initialValue: "default")
            _customEffort = State(initialValue: "")
        } else if Self.presetLevels.contains(stored) {
            _effortSelection = State(initialValue: stored)
            _customEffort = State(initialValue: stored)
        } else {
            _effortSelection = State(initialValue: "custom")
            _customEffort = State(initialValue: stored)
        }
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(template.name.isEmpty ? "New Template" : "Edit Template")
                .font(.headline)

            TextField("Name", text: $template.name)

            TextField("Prompt, use [placeholder] for the selection", text: $template.prompt, axis: .vertical)
                .lineLimit(4...10)

            Picker("Model", selection: Binding(
                get: { template.modelID },
                set: { template.modelID = $0 }
            )) {
                Text("Default chat model").tag(Optional<UUID>.none)
                ForEach(CompanionConfigService.chatProviders()) { provider in
                    Section(provider.name) {
                        ForEach(provider.models) { model in
                            Text(model.name).tag(Optional(model.id))
                        }
                    }
                }
            }

            Picker("Action", selection: Binding(
                get: { template.action },
                set: { template.action = $0 }
            )) {
                Text("Show overlay").tag(TemplateAction.overlay)
                Text("Replace selection").tag(TemplateAction.replace)
                Text("Insert after selection").tag(TemplateAction.append)
            }
            .onChange(of: template.action) { _, _ in
                template.autoReplace = template.action == .replace
            }

            Picker("Reasoning effort", selection: $effortSelection) {
                Text("Default").tag("default")
                ForEach(templateEffortOptions, id: \.self) { level in
                    Text(level.capitalized).tag(level)
                }
                Text("Custom").tag("custom")
            }
            .onChange(of: effortSelection) { _, newValue in
                switch newValue {
                case "default":
                    template.reasoningEffort = nil
                case "custom":
                    template.reasoningEffort = customEffort.isEmpty ? nil : customEffort
                default:
                    template.reasoningEffort = newValue
                }
            }
            if effortSelection == "custom" {
                TextField("Custom effort value", text: $customEffort)
                    .onChange(of: customEffort) { _, newValue in
                        template.reasoningEffort = newValue.isEmpty ? nil : newValue
                    }
            }

            Text("The model picker pins this template to one provider model; the default chat model applies when none is picked. Only OpenAI-compatible providers list models here, the ACP backend keeps using its own agent.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if effortSelection == "custom", customEffort.isEmpty {
                        template.reasoningEffort = nil
                    }
                    onSave(template)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(template.name.isEmpty || template.prompt.isEmpty)
            }
        }
        .frame(width: 420, height: 400)
        .padding()
    }
}
